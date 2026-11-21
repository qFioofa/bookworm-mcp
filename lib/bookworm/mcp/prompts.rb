# frozen_string_literal: true

module Bookworm
  module MCP
    module Prompts
      module_function

      def arguments
        %w[request document_id language].map do |name|
          meta = "scenarios.prompt.arguments_meta.#{name}"
          ::MCP::Prompt::Argument.new(
            name: name,
            title: Bookworm::I18n.t("#{meta}.title"),
            description: Bookworm::I18n.t("#{meta}.description"),
            required: name == "request"
          )
        end
      end

      def build(scenario)
        ::MCP::Prompt.define(
          name: "scenario_#{scenario.id}",
          title: scenario.title,
          description: scenario.description,
          arguments: arguments
        ) do |args, server_context: nil|
          ::MCP::Prompt::Result.new(
            description: scenario.description,
            messages: [
              ::MCP::Prompt::Message.new(
                role: "user",
                content: ::MCP::Content::Text.new(
                  Bookworm::Scenarios::Renderer.call(scenario, args)
                )
              )
            ]
          )
        end
      end

      ALL = Bookworm::Scenarios::Catalog.all.map { |scenario| build(scenario) }.freeze

      def by_name(name)
        ALL.find { |prompt| prompt.name_value == name.to_s }
      end
    end
  end
end
