#! /usr/bin/env ruby
require 'yaml'
require 'fileutils'

CONFIG_DIR = File.join(__dir__, "..", "..", "config", "crd", "bases")
OUT_DIR = File.join(__dir__, "..", "content", "docs", "development", "crds")
FILES = [
    "carto.run_clusterconfigtemplates.yaml",
    "carto.run_clusterdeliveries.yaml",
    "carto.run_clusterdeploymenttemplates.yaml",
    "carto.run_clusterimagetemplates.yaml",
    "carto.run_clusterruntemplates.yaml",
    "carto.run_clustersourcetemplates.yaml",
    "carto.run_clustersupplychains.yaml",
    "carto.run_clustertemplates.yaml",
    "carto.run_deliverables.yaml",
    "carto.run_runnables.yaml",
    "carto.run_workloads.yaml",
]

SCHEMA_SKIPS = {
    "apiVersion" => nil,
    "kind" => nil,
    "status" => nil,
}

class Object
    def skip? key
        self.has_key?(key) && self[key].nil?
    end

    def get_skip key
        self[key] || {}
    end
end

class String
  def word_wrap( col_width=80 )
    self.dup.word_wrap!( col_width )
  end

  def word_wrap!( col_width=80 )
    # commented this out as it forces long lines split (URLS get smashed)
    # self.gsub!( /(\S{#{col_width}})(?=\S)/, '\1 ' )
    self.gsub!( /(.{1,#{col_width}})(?:\s+|$)/, "\\1\n" )
    self
  end
end

class Writer
    attr_accessor :out
    attr_accessor :wrap

    def initialize out=$stdout, wrap=64
        @indent = 0
        @out = out
        @wrap = wrap
        @array_mode = false
    end

    def indent
        @indent += 1
    end

    def indent_array
        @indent += 2
        @array_mode = true
    end

    def outdent
        @indent -= 1
    end

    def outdent_array
        @indent -= 2
        @array_mode = false
    end

    def puts msg=""
        indent = gen_indent
        @out.puts("#{indent}#{msg}")
    end

    def comment comment
        indent = gen_indent
        comment_lines = comment.word_wrap(@wrap - indent.length)
        comment_lines.split("\n").each do |line|
            if @array_mode then
                @array_mode = false
                @out.puts("#{indent[0...-2]}- # #{line}")
            else
                @out.puts("#{indent}# #{line}")
            end
        end
    end

    private

    def gen_indent
        "  " * @indent
    end
end


def key_header(o,schemaObj)
    return unless schemaObj.has_key?("description")
    o.puts
    o.comment schemaObj['description']
end

def add_object(o, name, schemaObj, skips)
    key_header o,schemaObj

    unless schemaObj.has_key? "properties"
        o.puts "#{name}: <object>"
        return
    end

    o.puts "#{name}:"
    o.indent
    add_properties(o,schemaObj,skips)
    o.outdent
end


def add_array(o, name, schemaObj, skips)
    key_header o,schemaObj

    unless schemaObj.has_key? "items"
        o.puts "#{name}: <array>"
        return
    end

    o.puts "#{name}:"
    o.indent_array
    add_properties(o,schemaObj["items"],skips)
    o.outdent_array
end

def add_scalar(o, name, schemaObj)
    key_header o,schemaObj

    o.puts "#{name}: <#{schemaObj["type"]}>"
end


def add_properties(o, schemaObj, skips)

    schemaObj["properties"].each do |name, source|
        next if skips.skip? name

        type = source["type"]
        case type
        when "object"
            add_object(o,name,source,skips.get_skip(name))
        when "array"
            add_array(o,name,source,skips.get_skip(name))
        else
            add_scalar(o,name,source)
        end
    end
end



FileUtils.mkdir_p OUT_DIR


FILES.each do |filename|
    f = File.open(File.join(OUT_DIR, filename), "w")
    o = Writer.new(f)
    crd = YAML.load_file(File.join(CONFIG_DIR,filename))
    spec = crd["spec"]
    spec["versions"].each do |version|
        schema = version["schema"]["openAPIV3Schema"]


        o.puts "---"
        o.puts "apiVersion: #{spec['group']}/#{version['name']}"
        o.puts "kind: #{spec["names"]["kind"]}"

        add_properties(o, schema, SCHEMA_SKIPS)
    end
end

