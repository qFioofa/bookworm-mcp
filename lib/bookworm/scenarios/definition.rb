# frozen_string_literal: true

module Bookworm
  module Scenarios
    class Definition
      attr_reader :id, :steps, :guardrails

      def initialize(id:, steps:, guardrails: [], stop_when: nil, output: nil)
        @id = id.to_s
        @steps = normalize_steps(steps)
        @guardrails = Array(guardrails).map(&:to_s).freeze
        @stop_when = stop_when
        @output = output
        validate!
        freeze
      end

      def title
        Bookworm::I18n.t("scenarios.#{id}.title")
      end

      def description
        Bookworm::I18n.t("scenarios.#{id}.description")
      end

      def when_to_use
        Bookworm::I18n.t("scenarios.#{id}.when")
      end

      def stop_when
        @stop_when ? Bookworm::I18n.t(@stop_when) : nil
      end

      def output
        @output ? Bookworm::I18n.t(@output) : nil
      end

      def guardrail_texts
        guardrails.map { |key| Bookworm::I18n.t(key) }
      end

      def tool_names
        steps.map { |step| step[:tool] }
      end

      def step_note(step)
        key = step[:note_key] || "scenarios.step_notes.#{step[:tool]}"
        Bookworm::I18n.t(key, default: "")
      end

      private

      def normalize_steps(steps)
        Array(steps).map do |step|
          entry = step.transform_keys(&:to_sym)
          {
            tool: entry.fetch(:tool).to_s,
            args: normalize_args(entry[:args]),
            requires: entry[:requires]&.to_s,
            note_key: entry[:note_key]&.to_s
          }.freeze
        end.freeze
      end

      def normalize_args(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), result|
            result[key.to_sym] = normalize_args(item)
          end.freeze
        when Array
          value.map { |item| normalize_args(item) }.freeze
        else
          value
        end
      end

      def validate!
        raise ValidationError, "Scenario id must not be empty" if id.empty?
        raise ValidationError, "Scenario #{id} has no steps" if steps.empty?

        missing = steps.select { |step| step[:tool].to_s.empty? }
        raise ValidationError, "Scenario #{id} has a step without a tool" if missing.any?
      end
    end
  end
end
