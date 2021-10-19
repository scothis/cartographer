// Copyright 2021 VMware
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package pipeline

//go:generate go run github.com/maxbrunsfeld/counterfeiter/v6 -generate

import (
	"context"
	"fmt"

	"github.com/go-logr/logr"
	v1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"

	"github.com/vmware-tanzu/cartographer/pkg/apis/v1alpha1"
	"github.com/vmware-tanzu/cartographer/pkg/repository"
	"github.com/vmware-tanzu/cartographer/pkg/templates"
)

//counterfeiter:generate . Realizer
type Realizer interface {
	Realize(ctx context.Context, pipeline *v1alpha1.Pipeline, logger logr.Logger, repository repository.Repository) (*v1.Condition, templates.Outputs, *unstructured.Unstructured)
}

func NewRealizer() Realizer {
	return &pipelineRealizer{}
}

type pipelineRealizer struct{}

type TemplatingContext struct {
	Pipeline *v1alpha1.Pipeline     `json:"pipeline"`
	Selected map[string]interface{} `json:"selected"`
}

func (p *pipelineRealizer) Realize(ctx context.Context, pipeline *v1alpha1.Pipeline, logger logr.Logger, repository repository.Repository) (*v1.Condition, templates.Outputs, *unstructured.Unstructured) {
	pipeline.Spec.RunTemplateRef.Kind = "ClusterRunTemplate"
	template, err := repository.GetRunTemplate(pipeline.Spec.RunTemplateRef)

	if err != nil {
		errorMessage := fmt.Sprintf("could not get ClusterRunTemplate '%s'", pipeline.Spec.RunTemplateRef.Name)
		logger.Error(err, errorMessage)

		return RunTemplateMissingCondition(fmt.Errorf("%s: %w", errorMessage, err)), nil, nil
	}

	labels := map[string]string{
		"carto.run/pipeline-name":     pipeline.Name,
		"carto.run/run-template-name": template.GetName(),
	}

	selected, err := resolveSelector(pipeline.Spec.Selector, repository)
	if err != nil {
		errorMessage := fmt.Sprintf("could not resolve selector (apiVersion:%s kind:%s labels:%v)",
			pipeline.Spec.Selector.Resource.APIVersion,
			pipeline.Spec.Selector.Resource.Kind,
			pipeline.Spec.Selector.MatchingLabels)
		logger.Error(err, errorMessage)
		return TemplateStampFailureCondition(fmt.Errorf("%s: %w", errorMessage, err)), nil, nil
	}

	stampContext := templates.StamperBuilder(
		pipeline,
		TemplatingContext{
			Pipeline: pipeline,
			Selected: selected,
		},
		labels,
	)

	stampedObject, err := stampContext.Stamp(ctx, template.GetResourceTemplate())
	if err != nil {
		errorMessage := "could not stamp template"
		logger.Error(err, errorMessage)
		return TemplateStampFailureCondition(fmt.Errorf("%s: %w", errorMessage, err)), nil, nil
	}

	err = repository.EnsureObjectExistsOnCluster(stampedObject.DeepCopy(), false)
	if err != nil {
		errorMessage := "could not create object"
		logger.Error(err, errorMessage)
		return StampedObjectRejectedByAPIServerCondition(fmt.Errorf("%s: %w", errorMessage, err)), nil, nil
	}

	objectForListCall := stampedObject.DeepCopy()
	objectForListCall.SetLabels(labels)

	allPipelineStampedObjects, err := repository.ListUnstructured(objectForListCall)
	if err != nil {
		err := fmt.Errorf("could not list pipeline objects: %w", err)
		logger.Info(err.Error())
		return FailedToListCreatedObjectsCondition(err), nil, stampedObject
	}

	outputs, err := template.GetOutput(allPipelineStampedObjects)
	if err != nil {
		errorMessage := fmt.Sprintf("could not get output: %s", err.Error())
		logger.Info(errorMessage)
		return OutputPathNotSatisfiedCondition(err), nil, stampedObject
	}
	if len(outputs) == 0 {
		outputs = pipeline.Status.Outputs
	}

	return RunTemplateReadyCondition(), outputs, stampedObject
}

func resolveSelector(selector *v1alpha1.ResourceSelector, repository repository.Repository) (map[string]interface{}, error) {
	if selector == nil {
		return nil, nil
	}
	queryObj := &unstructured.Unstructured{}
	queryObj.SetGroupVersionKind(schema.FromAPIVersionAndKind(selector.Resource.APIVersion, selector.Resource.Kind))
	queryObj.SetLabels(selector.MatchingLabels)

	results, err := repository.ListUnstructured(queryObj)
	if err != nil {
		return nil, fmt.Errorf("could not list objects matching selector: %w", err)
	}

	if len(results) == 0 {
		return nil, fmt.Errorf("selector did not match any objects")
	} else if len(results) > 1 {
		return nil, fmt.Errorf("selector matched multiple objects")
	}
	return results[0].Object, nil
}
