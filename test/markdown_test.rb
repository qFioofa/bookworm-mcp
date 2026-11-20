# frozen_string_literal: true

require_relative "test_helper"

class MarkdownTest < Minitest::Test
  def setup
    @app = Bookworm::App.new
    @document = @app.ingest_text(
      <<~MARKDOWN,
        # Chapter One

        Loss aversion is a cognitive bias.

        ## Section A

        For example, an investor refuses to sell a losing stock.

        # Chapter Two

        Risk seeking can appear when a person faces certain loss.
      MARKDOWN
      title: "Markdown book",
      format: "markdown"
    )
  end

  def test_outline_contains_chapters
    outline = @app.get_outline(document_id: @document.id, depth: 3)

    assert_equal 2, outline[:root][:children].length
    assert_equal "Chapter One", outline[:root][:children].first[:title]
    assert_equal "Section A", outline[:root][:children].first[:children].first[:title]
  end

  def test_search_can_be_scoped_to_node
    outline = @app.get_outline(document_id: @document.id, depth: 3)
    section = outline[:root][:children].first[:children].first

    result = @app.search(
      query: "investor",
      document_id: @document.id,
      filters: { node_id: section[:node_id] }
    )

    assert_equal 1, result[:total]
    assert_equal "Section A", result[:hits].first[:citation][:chapter_path].last
  end
end
