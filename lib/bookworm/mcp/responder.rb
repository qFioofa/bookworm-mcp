# frozen_string_literal: true

require "json"

module Bookworm
  module MCP
    module Responder
      module_function

      def call
        result = yield
        response(result)
      rescue Bookworm::Error => e
        failure(e.code, e.message, e.details)
      rescue StandardError => e
        failure("INTERNAL_ERROR", e.message, {})
      end

      def response(result)
        ::MCP::Tool::Response.new(
          [{ type: "text", text: JSON.pretty_generate(result) }],
          structured_content: result
        )
      end

      def failure(code, message, details = {})
        localized = Bookworm::I18n.t("errors.#{code.to_s.downcase}", default: message)
        payload = { error: { code: code, message: localized, details: details } }
        # Do not attach structured_content to error responses. Some MCP clients
        # validate structuredContent against the tool output schema even when
        # isError is true, which hides the real error behind a schema mismatch.
        ::MCP::Tool::Response.new(
          [{ type: "text", text: JSON.pretty_generate(payload) }],
          error: true
        )
      end
    end
  end
end
