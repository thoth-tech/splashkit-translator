require_relative 'abstract_translator'

module Translators
  #
  # C# WASM binding generator (primitive-only)
  #
  class CSharpWasm < AbstractTranslator
    PRIMITIVE_TYPES = %w[
      void bool char int short long float double string
    ].to_set

    def initialize(data, logging = false)
      super(data, logging)
    end

    def render_templates
      grouped = grouped_data
      {
        'SplashKitBindings.Generated.cs' => render_csharp_bindings(grouped_data),
        'splashKitMethods.generated.js' => render_method_names_js(grouped)
      }
    end

    def grouped_data
      @data
        .group_by { |_, header| header[:group] }
        .map do |group_key, group_data|
          tmpl = {
            brief: '', description: '', functions: [],
            typedefs: [], structs: [], enums: [], defines: []
          }
          merged = group_data.to_h.values.reduce(tmpl) do |memo, h|
            h.each { |k, v| memo[k] += v if v && memo.key?(k) && !v.empty? }
            memo
          end
          map_signatures(merged)
          [group_key, merged]
        end
        .sort
        .to_h
    end

    def run_for_each_adapter
      Translators.adapters.each { |cls| yield cls.new(@data) }
    end

    def map_signatures(data)
      run_for_each_adapter do |adpt|
        key = adpt.name.to_s.downcase

        data[:functions].each do |fn|
          fn[:signatures] ||= {}
          fn[:signatures][key] =
            if adpt.respond_to?(:docs_signatures_for)
              adpt.docs_signatures_for(fn)
            else
              adpt.sk_signature_for(fn)
            end
        end

        data[:enums].each do |enum|
          enum[:signatures] ||= {}
          vals = enum[:constants].map do |n, d|
            {
              name: n.to_s,
              description: d[:description] || '',
              value: d[:number] || 0
            }
          end
          if adpt.respond_to?(:enum_signature_syntax)
            enum[:signatures][key] = adpt.enum_signature_syntax(enum[:name], vals)
          end
        end
      end
    end

    def render_csharp_bindings(grouped)
      lines = []
      lines << 'using System.Runtime.InteropServices.JavaScript;'
      lines << ''
      lines << 'namespace SplashKitSDK'
      lines << '{'
      lines << '    public partial class SplashKit'
      lines << '    {'

      grouped.each_value do |grp|
        grp[:functions].each do |fn|
          sigs = fn[:signatures] || {}
          raw = sigs['csharpwasm'] || sigs['csharp']
          next unless raw

          arr = raw.is_a?(Array) ? raw : [raw]
          sig_line = arr.find { |s| s =~ /public static .*SplashKit\./ } || arr.find { |s| s =~ /\w+\(.*\)/ }
          next unless sig_line

          if sig_line =~ /public\s+static\s+(\w+)\s+SplashKit\.(\w+)\((.*)\);?/
            ret, fn_name, params = $1, $2, $3
            next unless primitive_type?(ret)

            param_list = params.strip.split(',').map do |p|
              p.strip.split(' ', 2)
            end
            next unless param_list.all? { |t, _n| primitive_type?(t) }

            cs_method = fn_name.gsub(/(?:^|_)([a-z])/) { $1.upcase }
            cs_params = param_list.map { |t, n| "#{cs_type(t)} #{n}" }.join(', ')

            lines << "        [JSImport(\"SplashKitBackendWASM.#{fn[:name]}\", \"main.js\")]"
            lines << "        public static partial #{cs_type(ret)} #{cs_method}(#{cs_params});"
            lines << ''
          end
        end
      end

      lines << '    }'
      lines << '}'
      lines.join("\n")
    end

    def render_method_names_js(grouped)
      method_names = grouped.values.flat_map do |grp|
        grp[:functions].map { |fn| fn[:name] }
      end.uniq.sort

      lines = []
      lines << 'const methods = `'
      lines += method_names.map.with_index do |name, i|
        suffix = i == method_names.size - 1 ? '' : ','
        "  #{name}#{suffix}"
      end
      lines << '`;'
      lines << ''
      lines << 'export default methods;'

      lines.join("\n")
    end

    def post_execute
      puts 'Place `splashKitMethods.generated.js` and `SplashKitBindings.Generated.cs` in `generated/csharpwasm` of the `splashkit-core` repo'
    end

    private

    def cs_type(type)
      {
        'int' => 'int',
        'float' => 'float',
        'double' => 'double',
        'bool' => 'bool',
        'char' => 'char',
        'void' => 'void',
        'string' => 'string'
      }[type] || type.split('_').map(&:capitalize).join
    end

    def primitive_type?(type)
      PRIMITIVE_TYPES.include?(type.downcase)
    end
  end
end
