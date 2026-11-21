# frozen_string_literal: true

require "json"

module Bookworm
  module Scenarios
    module Renderer
      PLACEHOLDER = /\{\{(\w+)\}\}/.freeze

      module_function

      def call(scenario, args = {})
        values = normalize_values(args)
        lines = []
        lines << Bookworm::I18n.t("scenarios.prompt.heading", title: scenario.title)
        lines << ""
        lines << scenario.description
        lines << ""
        lines << "#{Bookworm::I18n.t("scenarios.prompt.when")}: #{scenario.when_to_use}"
        lines << "#{Bookworm::I18n.t("scenarios.prompt.request")}: #{values["request"]}"
        lines << "#{Bookworm::I18n.t("scenarios.prompt.document")}: #{document_scope(values)}"
        lines << "#{Bookworm::I18n.t("scenarios.prompt.language")}: #{values["language"]}" if present(values["language"])
        lines << ""

        steps = render_steps(scenario, values)
        if steps.empty?
          lines << "#{Bookworm::I18n.t("scenarios.prompt.steps")}: #{Bookworm::I18n.t("scenarios.prompt.no_steps")}"
        else
          lines << "#{Bookworm::I18n.t("scenarios.prompt.steps")}:"
          lines.concat(steps)
        end

        if scenario.stop_when
          lines << ""
          lines << "#{Bookworm::I18n.t("scenarios.prompt.stop_when")}: #{scenario.stop_when}"
        end

        if scenario.output
          lines << "#{Bookworm::I18n.t("scenarios.prompt.expected")}: #{scenario.output}"
        end

        constraints = scenario.guardrail_texts.reject { |text| text.to_s.empty? }
        unless constraints.empty?
          lines << ""
          lines << "#{Bookworm::I18n.t("scenarios.prompt.constraints")}:"
          constraints.each { |text| lines << "- #{text}" }
        end

        lines.join("\n")
      end

      def render_steps(scenario, values)
        usable = scenario.steps.select { |step| usable?(step, values) }
        usable.each_with_index.map do |step, index|
          rendered = interpolate(step[:args], values) || {}
          note = scenario.step_note(step).to_s
          note = note.empty? ? "" : " — #{note}"
          args = rendered.empty? ? "" : "; #{Bookworm::I18n.t("scenarios.prompt.arguments")}: #{JSON.generate(rendered)}"
          "#{index + 1}. `#{step[:tool]}`#{note}#{args}"
        end
      end

      def usable?(step, values)
        return true if step[:requires].nil?

        present(values[step[:requires]])
      end

      def document_scope(values)
        present(values["document_id"]) || Bookworm::I18n.t("scenarios.prompt.no_document")
      end

      def normalize_values(args)
        (args || {}).each_with_object({}) do |(key, value), result|
          result[key.to_s] = value.to_s.strip
        end
      end

      def interpolate(value, values)
        case value
        when String
          if (match = value.match(/\A\{\{(\w+)\}\}\z/))
            present(values[match[1]])
          else
            value.gsub(PLACEHOLDER) { values[Regexp.last_match(1)].to_s }
          end
        when Hash
          value.each_with_object({}) do |(key, item), result|
            rendered = interpolate(item, values)
            result[key] = rendered unless rendered.nil?
          end
        when Array
          value.filter_map { |item| interpolate(item, values) }
        else
          value
        end
      end

      def present(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
