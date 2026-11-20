# frozen_string_literal: true

require_relative "test_helper"

class GraphTest < Minitest::Test
  def setup
    @app = Bookworm::App.new
    @document = @app.ingest_text(
      <<~TEXT,
        Loss aversion is a cognitive bias. Daniel Kahneman and Amos Tversky studied loss aversion.

        Loss aversion causes risk seeking when a person faces a certain loss. For example, an investor refuses to sell a losing stock.

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

    full = @app.get_case(example[:case_id])
    assert_equal example[:case_id], full[:case][:case_id]
    refute_empty full[:case][:text]
  end
end
