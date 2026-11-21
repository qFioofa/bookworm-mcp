# frozen_string_literal: true

require_relative "test_helper"

class ScenariosTest < Minitest::Test
  def setup
    @app = Bookworm::App.new
    @server = Bookworm::MCP.build_server(@app)
  end

  def teardown
    Bookworm::I18n.setup!(locale: "en")
  end

  def call(method, params = nil, id: 1)
    request = { jsonrpc: "2.0", id: id, method: method }
    request[:params] = params if params
    JSON.parse(@server.handle_json(JSON.generate(request)))
  end

  def prompt_text(response)
    response.dig("result", "messages", 0, "content", "text")
  end

  def test_catalog_loads_all_scenarios_with_unique_ids
    scenarios = Bookworm::Scenarios::Catalog.all
    ids = scenarios.map(&:id)

    assert_equal 10, scenarios.length
    assert_equal ids.length, ids.uniq.length
    assert_includes ids, "fact_lookup"
    assert_includes ids, "quote_verification"
    assert_includes ids, "cross_book_comparison"
  end

  def test_catalog_only_uses_known_tools
    known = Bookworm::MCP::Tools::ALL.map(&:name_value)
    used = Bookworm::Scenarios::Catalog.all.flat_map(&:tool_names).uniq

    assert_empty used - known
    refute_empty used
  end

  def test_prompts_list_exposes_every_scenario
    response = call("prompts/list")
    prompts = response.dig("result", "prompts")

    assert_equal Bookworm::Scenarios::Catalog.all.length, prompts.length
    names = prompts.map { |prompt| prompt["name"] }
    assert_includes names, "scenario_fact_lookup"
    assert_includes names, "scenario_quote_verification"

    prompt = prompts.find { |item| item["name"] == "scenario_fact_lookup" }
    argument_names = prompt["arguments"].map { |argument| argument["name"] }
    assert_equal %w[request document_id language], argument_names
    assert prompt["arguments"].find { |argument| argument["name"] == "request" }["required"]
  end

  def test_prompt_get_renders_recipe_and_interpolates_document_id
    response = call(
      "prompts/get",
      {
        name: "scenario_fact_lookup",
        arguments: { request: "what is loss aversion", document_id: "doc_1" }
      }
    )
    text = prompt_text(response)

    assert_includes text, "Bookworm scenario: Fact or thesis lookup"
    assert_includes text, "Request: what is loss aversion"
    assert_includes text, "Document scope: doc_1"
    assert_includes text, "`search`"
    assert_includes text, "`read_passage`"
    assert_includes text, "`find_quote`"
    assert_includes text, "\"document_id\":\"doc_1\""
    assert_includes text, "Every claim must carry a passage_id"
    refute response["error"], response.inspect
  end

  def test_prompt_get_skips_steps_that_require_a_missing_document
    response = call(
      "prompts/get",
      { name: "scenario_triage", arguments: { request: "what is available" } }
    )
    text = prompt_text(response)

    assert_includes text, "`list_documents`"
    assert_includes text, "`stats`"
    refute_includes text, "`get_document`"
    refute_includes text, "`get_outline`"
  end

  def test_renderer_drops_blank_optional_arguments
    scenario = Bookworm::Scenarios::Catalog.find("fact_lookup")
    text = Bookworm::Scenarios::Renderer.call(scenario, { request: "loss", document_id: "" })

    refute_includes text, "\"document_id\""
    assert_includes text, "Document scope: not specified"
  end

  def test_prompt_get_requires_request
    response = call("prompts/get", { name: "scenario_fact_lookup", arguments: {} })

    assert response["error"], response.inspect
    assert_equal(-32_602, response.dig("error", "code"))
  end

  def test_unknown_prompt_returns_error
    response = call("prompts/get", { name: "scenario_missing", arguments: { request: "x" } })

    assert response["error"], response.inspect
    assert_equal(-32_602, response.dig("error", "code"))
  end

  def test_russian_locale_renders_russian_scenario_text
    Bookworm::I18n.setup!(locale: "ru")
    scenario = Bookworm::Scenarios::Catalog.find("quote_verification")
    text = Bookworm::Scenarios::Renderer.call(scenario, { request: "проверь цитату" })

    assert_includes text, "Сценарий Bookworm: Проверка цитаты"
    assert_includes text, "Критерий остановки"
    assert_includes text, "Ограничения"
    assert_includes text, "verified=false"
  end
end
