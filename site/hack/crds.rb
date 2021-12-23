#! /usr/bin/env ruby
require 'yaml'
require 'fileutils'


CONFIG_DIR = File.join(__dir__, "crds")
CRD_DIR = File.join(__dir__, "..", "..", "config", "crd", "bases")
OUT_DIR = File.join(__dir__, "..", "content", "docs", "development", "crds")

HIDE_DESCRIPTION = "_hideDescription"
HIDE_CHILD_DESCRIPTIONS = "_hideChildDescriptions"
MAX_DEPTH = "_maxDepth"

class Config
  def initialize(obj, recursive_hide_description = false, max_depth = nil)
    @obj = obj
    @recursive_hide_description = recursive_hide_description
    @max_depth = max_depth
  end


  def [](field)
    Config.new(
        obj[field] || {},
        !!obj.dig(HIDE_CHILD_DESCRIPTIONS) || recursive_hide_description,
        obj.dig(MAX_DEPTH) && obj.dig(MAX_DEPTH).to_i - 1,
    )
  end

  def version
    obj["_version"]
  end

  def deleted?
    return true if obj.dig("_delete") == true
    @max_depth || 2 < 1
  end

  def hide_description?
    obj.dig(HIDE_DESCRIPTION) == true || recursive_hide_description
  end

  # todo add a validator so we can help with the config doc editing

  private

  attr_reader :obj,
      :recursive_hide_description,
      :max_depth



end

class String
  def word_wrap(col_width = 80)
    self.dup.word_wrap!(col_width)
  end

  def word_wrap!(col_width = 80)
    # commented this out as it forces long lines split (URLS get smashed)
    # self.gsub!( /(\S{#{col_width}})(?=\S)/, '\1 ' )
    self.gsub!(/(.{1,#{col_width}})(?:\s+|$)/, "\\1\n")
    self
  end
end

class Writer
  attr_accessor :out
  attr_accessor :wrap

  def initialize out = $stdout, wrap = 64
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

  def puts(msg = "")
    indent = gen_indent
    @out.puts("#{indent}#{msg}")
  end

  def comment(comment)
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


class DocGen

  def initialize(writer)
    @out = writer
  end

  def process_version(config, schema, spec)
    out.puts "---"
    out.puts "apiVersion: #{spec['group']}/#{config.version}"
    out.puts "kind: #{spec["names"]["kind"]}"

    add_properties(schema, config)
  end

  private

  attr_reader :out

  def key_header(schema_obj, config)
    return unless schema_obj.has_key?("description")
    return if config.hide_description?
    out.puts
    out.comment schema_obj['description']
  end

  def add_properties(schema_obj, config)
    schema_obj["properties"].each do |name, source|
      type = source["type"]
      child_config = config[name]
      case type
      when "object"
        add_object(name, source, child_config)
      when "array"
        add_array(name, source, child_config)
      else
        add_scalar(name, source, child_config)
      end
    end
  end

  def add_scalar(name, schema_obj, config)
    return if config.deleted?

    key_header schema_obj, config

    out.puts "#{name}: <#{schema_obj["type"]}>"
  end

  def add_object(name, schema_obj, config)
    return if config.deleted?

    key_header schema_obj, config

    unless schema_obj.has_key?("properties")
      out.puts "#{name}: <object>" # todo, need to count properties to fix the writer.
      return
    end

    out.puts "#{name}:"
    out.indent
    add_properties(schema_obj, config)
    out.outdent
  end

  def add_array(name, schema_obj, config)
    return if config.deleted?

    key_header schema_obj, config

    unless schema_obj.has_key? "items"
      out.puts "#{name}: <array>"
      return
    end

    out.puts "#{name}:"
    out.indent_array
    add_properties(schema_obj["items"], config)
    out.outdent_array
  end
end

def main
  FileUtils.mkdir_p OUT_DIR
  config_files = Dir.glob(File.join(CONFIG_DIR, '*.yaml'))

  config_files.each do |filename|
    puts "Processing: #{filename}"

    # Load Config
    config_object = YAML.load_file(filename)
    config_object["apiVersion"] = {"_delete" => true}
    config_object["kind"] = {"_delete" => true}

    config = Config.new(config_object)

    # Load Input CRD Spec
    input_filename = File.join(CRD_DIR, File.basename(filename))
    puts "\tSource CRD: #{File.absolute_path(input_filename)}"

    crd = YAML.load_file(input_filename)
    spec = crd["spec"]

    # Create/Open Target Spec Yaml
    output_filename = File.join(OUT_DIR, File.basename(filename))
    puts "\tTarget Resource Spec: #{File.absolute_path(output_filename)}"

    writer = Writer.new(File.open(output_filename, "w"))

    puts "\tUsing version (config._version): #{config.version}"

    version_spec = spec["versions"].find { |version| version["name"] == config.version }
    if version_spec.nil?
      puts "Error: version not found"
      next
    end

    schema = version_spec["schema"]["openAPIV3Schema"]
    DocGen.new(writer).process_version(config, schema, spec)

  end
end

main