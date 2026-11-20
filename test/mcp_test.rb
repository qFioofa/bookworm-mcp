# frozen_string_literal: true

require_relative "test_helper"

class McpTest < Minitest::Test
  def setup
    @app = Bookworm::App.new
    @server = Bookworm::MCP.build_server(@app)
  end

  def call(method, params = nil, id: 1)
    request = { jsonrpc: "2.0", id: id, method: method }
    request[:params] = params if params
    JSON.parse(@server.handle_json(JSON.generate(request)))
  end

  def test_tools_list
    response = call("tools/list")
    names = response.dig("result", "tools").map { |tool| tool["name"] }

    assert_includes names, "ingest_book"
    assert_includes names, "ingest_text"
    assert_includes names, "search"
    assert_includes names, "find_quote"
    assert_includes names, "read_passage"
    assert_includes names, "get_outline"
    assert_includes names, "search_entities"
    assert_includes names, "get_relations"
    assert_includes names, "get_logical_chain"
    assert_includes names, "find_cases"
  end

  def test_ingest_text_and_search_through_mcp
    ingest = call(
      "tools/call",
      {
        name: "ingest_text",
        arguments: {
          text: "Loss aversion is a bias. For example, investors refuse to sell losers.",
          title: "MCP text"
        }
      }
    )
    document = ingest.dig("result", "structuredContent", "document")
    refute_nil document
    document_id = document["document_id"]

    search = call(
      "tools/call",
      {
        name: "search",
        arguments: { query: "investors", document_id: document_id }
      },
      id: 2
    )
    payload = search.dig("result", "structuredContent")
    assert_equal false, search.dig("result", "isError")
    assert_operator payload["total"], :>=, 1
    assert_equal document_id, payload["hits"].first.dig("citation", "document_id")
  end

  def test_search_inline_text_without_ingest
    response = call(
      "tools/call",
      {
        name: "search",
        arguments: {
          query: "bias",
          text: "Loss aversion is a cognitive bias.",
          title: "Inline"
        }
      }
    )
    payload = response.dig("result", "structuredContent")

    assert_equal false, response.dig("result", "isError")
    assert_operator payload["total"], :>=, 1
    assert_equal "text", payload["hits"].first.dig("citation", "document_kind")
  end

  def test_find_quote_through_mcp
    ingest = call(
      "tools/call",
      {
        name: "ingest_text",
        arguments: { text: "A quoted sentence should be found.", title: "Quote" }
      }
    )
    document_id = ingest.dig("result", "structuredContent", "document", "document_id")

    quote = call(
      "tools/call",
      {
        name: "find_quote",
        arguments: { quote: "quoted sentence", document_id: document_id }
      },
      id: 2
    )
    payload = quote.dig("result", "structuredContent")
    assert_equal false, payload["no_evidence"]
    assert_equal true, payload["occurrences"].first["verified"]
  end

  def test_graph_and_cases_through_mcp
    ingest = call(
      "tools/call",
      {
        name: "ingest_text",
        arguments: {
          text: "Loss aversion is a bias. Loss aversion causes risk seeking. For example, an investor refuses to sell a losing stock.",
          title: "Graph text"
        }
      }
    )
    document_id = ingest.dig("result", "structuredContent", "document", "document_id")

    entities = call(
      "tools/call",
      { name: "search_entities", arguments: { query: "loss aversion", document_id: document_id } },
      id: 2
    ).dig("result", "structuredContent")
    refute_empty entities["entities"]
    entity_id = entities["entities"].first["entity_id"]

    relations = call(
      "tools/call",
      {
        name: "get_relations",
        arguments: { entity_id: entity_id, format: "plantuml", document_id: document_id }
      },
      id: 3
    ).dig("result", "structuredContent")
    assert_includes relations["plantuml"], "@startuml"
    assert_operator relations["edges"].length, :>=, 1

    cases = call(
      "tools/call",
      { name: "find_cases", arguments: { document_id: document_id, limit: 5 } },
      id: 4
    ).dig("result", "structuredContent")
    assert_operator cases["total"], :>=, 1
  end

  def test_error_message_is_localized
    Bookworm::I18n.setup!(locale: "ru")
    response = call(
      "tools/call",
      { name: "search", arguments: { query: "   " } }
    )

    assert_equal true, response.dig("result", "isError")
    assert_equal "Некорректный запрос", response.dig("result", "structuredContent", "error", "message")
  ensure
    Bookworm::I18n.setup!(locale: "en")
  end

  def test_invalid_query_is_a_tool_error
    response = call(
      "tools/call",
      { name: "search", arguments: { query: "   " } }
    )

    assert_equal true, response.dig("result", "isError")
    assert_equal "VALIDATION_ERROR", response.dig("result", "structuredContent", "error", "code")
  end
end
