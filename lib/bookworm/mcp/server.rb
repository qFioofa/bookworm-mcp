# frozen_string_literal: true

module Bookworm
  module MCP
    module_function

    def build_server(app)
      ::MCP::Server.new(
        name: "bookworm-mcp",
        version: Bookworm::VERSION,
        instructions: Bookworm::I18n.t("server.instructions"),
        tools: Tools::ALL,
        server_context: { app: app }
      )
    end
  end
end
