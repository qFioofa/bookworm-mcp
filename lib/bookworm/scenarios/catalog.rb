# frozen_string_literal: true

require "yaml"

module Bookworm
  module Scenarios
    class Catalog
      DEFAULT_PATH = File.expand_path("definitions.yml", __dir__)

      class << self
        def all
          @all ||= load
        end

        def load(path = DEFAULT_PATH)
          data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
          entries = Array(data).map { |entry| Definition.new(**symbolize_keys(entry)) }
          validate_unique_ids!(entries)
          validate_tools!(entries)
          entries.freeze
        end

        def reset!
          @all = nil
        end

        def find(id)
          all.find { |scenario| scenario.id == id.to_s }
        end

        def known_tool_names
          return [] unless defined?(Bookworm::MCP::Tools::ALL)

          Bookworm::MCP::Tools::ALL.map(&:name_value)
        end

        private

        def symbolize_keys(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, item), result|
              result[key.to_sym] = symbolize_keys(item)
            end
          when Array
            value.map { |item| symbolize_keys(item) }
          else
            value
          end
        end

        def validate_unique_ids!(entries)
          duplicates = entries.group_by(&:id).select { |_id, list| list.length > 1 }.keys
          return if duplicates.empty?

          raise ValidationError.new(
            "Duplicate scenario ids",
            details: { ids: duplicates }
          )
        end

        def validate_tools!(entries)
          known = known_tool_names
          return if known.empty?

          unknown = (entries.flat_map(&:tool_names).uniq - known).sort
          return if unknown.empty?

          raise ValidationError.new(
            "Unknown tools in scenario definitions",
            details: { tools: unknown, known: known.sort }
          )
        end
      end
    end
  end
end
