# frozen_string_literal: true

require_relative "test_helper"

class McpTest < Minitest::Test
  include FixtureHelpers

  def setup
    @app = Bookworm::App.new
    @server = Bookworm::MCP.build_server(@app)
  end

  def call(method, params = nil, id: 1)
    request = { jsonrpc: "2.0", id: id, method: method }
    request[:params] = params if params
    JSON.parse(@server.handle_json(JSON.generate(request)))
  end

  def error_payload(response)
    JSON.parse(response.dig("result", "content").first.fetch("text"))
  end

  def test_tools_list
    response = call("tools/list")
    names = response.dig("result", "tools").map { |tool| tool["name"] }

    assert_includes names, "ingest_book"
    assert_includes names, "ingest_books"
    assert_includes names, "ingest_text"
    assert_includes names, "search"
    assert_includes names, "find_quote"
    assert_includes names, "read_passage"
    assert_includes names, "read_chapter"
    assert_includes names, "get_outline"
    assert_includes names, "search_entities"
    assert_includes names, "get_relations"
    assert_includes names, "get_logical_chain"
    assert_includes names, "find_cases"
  end

  def test_ingest_book_returns_document_for_fb2_txt_epub_and_pdf
    with_tmpdir do |dir|
      fb2 = build_fb2(File.join(dir, "book.fb2"))
      txt = File.join(dir, "book.txt")
      File.write(txt, "Простая книга.\n\nВторой абзац для поиска.")
      epub = build_epub(File.join(dir, "book.epub"))
      pdf = build_pdf(File.join(dir, "book.pdf"))

      schema = ::MCP::Tool::OutputSchema.new(Bookworm::MCP::Schemas.ingest_output)
      [fb2, txt, epub, pdf].each_with_index do |path, index|
        response = call(
          "tools/call",
          { name: "ingest_book", arguments: { path: path } },
          id: index + 10
        )
        assert_equal false, response.dig("result", "isError"), path
        structured = response.dig("result", "structuredContent")
        schema.validate_result(structured)
        document = structured["document"]
        refute_nil document, path
        refute_empty document["document_id"], path
        assert_equal false, structured["cached"], path
      end
    end
  end

  def test_ingest_book_missing_file_returns_real_error_not_schema_mismatch
    response = call(
      "tools/call",
      { name: "ingest_book", arguments: { path: "/tmp/bookworm-definitely-missing.fb2" } }
    )

    assert_equal true, response.dig("result", "isError")
    payload = error_payload(response)
    assert_equal "NOT_FOUND", payload.dig("error", "code")
    assert_equal "file_not_found", payload.dig("error", "details", "reason")
    assert_includes payload.dig("error", "details", "hint"), "Docker"
    refute response.dig("result", "structuredContent")
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

  def test_read_chapter_through_mcp
    ingest = call(
      "tools/call",
      {
        name: "ingest_text",
        arguments: {
          text: "## Кейс. Роль\n\nМой ученик Павел начал бизнес.\n\nПартнер Павла не согласился.",
          title: "Chapter text",
          format: "markdown"
        }
      }
    )
    document_id = ingest.dig("result", "structuredContent", "document", "document_id")

    outline = call(
      "tools/call",
      { name: "get_outline", arguments: { document_id: document_id } },
      id: 2
    ).dig("result", "structuredContent")
    node = outline.dig("root", "children").first
    refute_nil node

    chapter = call(
      "tools/call",
      {
        name: "read_chapter",
        arguments: { document_id: document_id, node_id: node["node_id"] }
      },
      id: 3
    ).dig("result", "structuredContent")

    assert_equal node["node_id"], chapter.dig("node", "node_id")
    assert_equal 2, chapter["returned"]
    assert_equal "text", chapter["document"]["kind"]
    assert chapter["passages"].all? { |passage| passage["citation"]["verified"] }
  end

  def test_ingest_text_is_cached_through_mcp
    arguments = { text: "Cached text", title: "Cache" }
    first = call("tools/call", { name: "ingest_text", arguments: arguments })
    second = call("tools/call", { name: "ingest_text", arguments: arguments }, id: 2)

    assert_equal false, first.dig("result", "structuredContent", "cached")
    assert_equal true, second.dig("result", "structuredContent", "cached")
    assert_equal(
      first.dig("result", "structuredContent", "document", "document_id"),
      second.dig("result", "structuredContent", "document", "document_id")
    )
  end

  def test_compact_outline_matches_output_schema
    ingest = call(
      "tools/call",
      {
        name: "ingest_text",
        arguments: {
          text: "# One\n\nA.\n\n## A1\n\nB.\n\n# Two\n\nC.",
          title: "Outline text",
          format: "markdown"
        }
      }
    )
    document_id = ingest.dig("result", "structuredContent", "document", "document_id")

    response = call(
      "tools/call",
      {
        name: "get_outline",
        arguments: { document_id: document_id, max_nodes: 2, titles_only: true }
      },
      id: 2
    )
    structured = response.dig("result", "structuredContent")
    schema = ::MCP::Tool::OutputSchema.new(Bookworm::MCP::Schemas.outline_output)
    schema.validate_result(structured)

    assert_equal 2, structured["returned_nodes"]
    assert_equal true, structured["truncated"]
    refute structured.dig("root", "children", 0).key?("content_start_char")
  end

  def test_relations_min_confidence_matches_output_schema
    ingest = call(
      "tools/call",
      {
        name: "ingest_text",
        arguments: {
          text: "«Модуль» входит в «Систему». «Модуль» и «Система» важны для примера.",
          title: "Graph"
        }
      }
    )
    document_id = ingest.dig("result", "structuredContent", "document", "document_id")

    response = call(
      "tools/call",
      {
        name: "get_relations",
        arguments: { document_id: document_id, min_confidence: 0 }
      },
      id: 2
    )
    structured = response.dig("result", "structuredContent")
    schema = ::MCP::Tool::OutputSchema.new(Bookworm::MCP::Schemas.graph_output)
    schema.validate_result(structured)

    assert_equal 0.0, structured["min_confidence"]
    assert structured["edges"].any? { |edge| edge["predicate"] == "CO_OCCURS" }
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
          text: "Loss aversion is a bias. Loss aversion causes risk seeking. Risk seeking follows a certain loss. For example, an investor refuses to sell a losing stock.",
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
    assert_equal "Некорректный запрос", error_payload(response).dig("error", "message")
    refute response.dig("result", "structuredContent")
  ensure
    Bookworm::I18n.setup!(locale: "en")
  end

  def test_invalid_query_is_a_tool_error
    response = call(
      "tools/call",
      { name: "search", arguments: { query: "   " } }
    )

    assert_equal true, response.dig("result", "isError")
    assert_equal "VALIDATION_ERROR", error_payload(response).dig("error", "code")
    refute response.dig("result", "structuredContent")
  end
end
