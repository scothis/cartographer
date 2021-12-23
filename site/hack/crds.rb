#! /usr/bin/env ruby
require 'yaml'
require 'fileutils'


CONFIG_DIR = File.join(__dir__, "crds")
CRD_DIR = File.join(__dir__, "..", "..", "config", "crd", "bases")
OUT_DIR = File.join(__dir__, "..", "content", "docs", "development", "crds")

class Config
  def initialize(obj)
    @obj = obj
  end

  def [](field)
    Config.new(obj[field] || {})
  end

  def version
    obj["_version"]
  end

  def deleted?(field)
    obj.dig(field, "_delete") == true
  end

  # todo add a validator so we can help with the config doc editing

  private

  attr_reader :obj

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

  def key_header(schema_obj)
    return unless schema_obj.has_key?("description")
    out.puts
    out.comment schema_obj['description']
  end

  def add_properties(schema_obj, config)
    schema_obj["properties"].each do |name, source|
      next if config.deleted? name
      type = source["type"]
      case type
      when "object"
        add_object(name, source, config[name])
      when "array"
        add_array(name, source, config[name])
      else
        add_scalar(name, source)
      end
    end
  end

  def add_scalar(name, schema_obj)
    key_header schema_obj

    out.puts "#{name}: <#{schema_obj["type"]}>"
  end

  def add_object(name, schema_obj, config)
    key_header schema_obj

    unless schema_obj.has_key? "properties"
      out.puts "#{name}: <object>"
      return
    end

    out.puts "#{name}:"
    out.indent
    add_properties(schema_obj, config)
    out.outdent
  end

  def add_array(name, schema_obj, config)
    key_header schema_obj

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