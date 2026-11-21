# frozen_string_literal: true

require_relative "test_helper"

class GraphTest < Minitest::Test
  def setup
    @app = Bookworm::App.new
    @document = @app.ingest_text(
      <<~TEXT,
        Loss aversion is a cognitive bias. Daniel Kahneman and Amos Tversky studied loss aversion.

        Loss aversion causes risk seeking when a person faces a certain loss. Risk seeking often follows a certain loss. For example, an investor refuses to sell a losing stock.

        Prospect theory includes loss aversion and reference dependence. Prospect theory contrasts with expected utility theory.

        For example, a patient may choose a risky treatment to avoid a certain loss.
      TEXT
      title: "Loss aversion and risk"
    )
  end

  def test_search_entities_finds_extracted_terms
    result = @app.search_entities(query: "loss aversion", document_id: @document.id)

    assert_operator result[:total], :>=, 1
    entity = result[:entities].first
    assert_equal "Loss aversion", entity[:name]
    assert_equal "term", entity[:type]
    assert_operator entity[:mention_count], :>=, 2
  end

  def test_get_entity_returns_mentions_and_relations
    entity = @app.search_entities(query: "loss aversion", limit: 1)[:entities].first
    result = @app.get_entity(entity[:entity_id])

    assert_equal entity[:entity_id], result[:entity][:entity_id]
    refute_empty result[:mentions]
    refute_empty result[:relations]
    assert result[:relations].any? { |relation| %w[CAUSES IS_A INCLUDES].include?(relation[:predicate]) }
  end

  def test_get_relations_returns_plantuml
    entity = @app.search_entities(query: "loss aversion", limit: 1)[:entities].first
    result = @app.get_relations(
      entity_id: entity[:entity_id],
      depth: 1,
      format: "plantuml",
      max_nodes: 20
    )

    assert_operator result[:nodes].length, :>=, 2
    assert_operator result[:edges].length, :>=, 1
    assert_includes result[:plantuml], "@startuml"
    assert_includes result[:plantuml], "CAUSES"
    assert_includes result[:plantuml], "@enduml"
  end

  def test_logical_chain
    result = @app.get_logical_chain(
      start: "Loss aversion",
      finish: "risk seeking",
      format: "plantuml"
    )

    assert_equal "complete", result[:completeness]
    assert_equal 1, result[:hops]
    assert_equal "CAUSES", result[:edges].first[:predicate]
    assert_includes result[:plantuml], "Loss aversion"
  end

  def test_find_cases_and_get_case
    result = @app.find_cases(query: "loss", limit: 5)

    assert_operator result[:total], :>=, 1
    example = result[:cases].first
    assert_equal "example", example[:kind]
    refute_empty example[:markers]
    assert_operator example[:passage_ids].length, :>=, 1

    full = @app.get_case(example[:case_id])
    assert_equal example[:case_id], full[:case][:case_id]
    refute_empty full[:case][:text]
    refute_empty full[:passages]
  end

  def test_entity_noise_is_filtered
    document = @app.ingest_text(
      "АНАЛИЗ показывает, что бояться повторять не стоит. Воздействие одно, двух сторон мало.",
      title: "Noise"
    )

    result = @app.search_entities(document_id: document.id, limit: 50)
    names = result[:entities].map { |entity| entity[:name] }

    refute_includes names, "АНАЛИЗ"
    assert names.none? { |name| name.include?("бояться") || name.include?("Воздействие одно") || name.include?("двух сторон") }
  end

  def test_weak_co_occurs_edges_are_hidden_by_default
    default = @app.get_relations(document_id: @document.id, limit: 500)
    refute default[:edges].any? { |edge| edge[:predicate] == "CO_OCCURS" }
    assert_equal 0.5, default[:min_confidence]

    with_weak = @app.get_relations(document_id: @document.id, limit: 500, min_confidence: 0)
    assert with_weak[:edges].any? { |edge| edge[:predicate] == "CO_OCCURS" }
  end

  def test_entity_relations_omit_weak_edges
    entity = @app.search_entities(query: "loss aversion", limit: 1)[:entities].first
    relations = @app.get_entity(entity[:entity_id])[:relations]

    refute relations.any? { |relation| relation[:predicate] == "CO_OCCURS" }
  end

  def test_part_of_relation_is_typed
    document = @app.ingest_text(
      "«Модуль» входит в «Систему». «Система» включает «Модуль».",
      title: "Part of"
    )

    graph = @app.get_relations(document_id: document.id, include_evidence: false)
    assert graph[:edges].any? { |edge| edge[:predicate] == "PART_OF" }
    assert graph[:edges].any? { |edge| edge[:predicate] == "INCLUDES" }
  end

  def test_case_section_is_merged_and_name_forms_are_linked
    document = @app.ingest_text(
      <<~TEXT,
        ## Кейс. Изменение роли

        Мой ученик Павел начал бизнес с партнером.

        Мой партнер Павла не согласился с новой ролью.

        Мой партнер предложил Павлу выйти из бизнеса.
      TEXT
      title: "Case merge",
      format: "markdown"
    )

    entities = @app.search_entities(query: "Павел", document_id: document.id)
    entity = entities[:entities].find { |item| item[:name] == "Павел" || item[:aliases].include?("Павел") }
    refute_nil entity
    assert_operator entity[:mention_count], :>=, 3
    assert_includes entity[:aliases], "Павла"

    cases = @app.find_cases(document_id: document.id, anchor: "Павел", limit: 5)
    assert_equal 1, cases[:total]
    merged = cases[:cases].first
    assert_equal "Кейс. Изменение роли", merged[:title]
    assert_equal 3, merged[:passage_ids].length
    assert_operator merged[:range][:end_char], :>, merged[:range][:start_char]
  end
end
