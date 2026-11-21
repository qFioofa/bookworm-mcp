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

  def test_outline_can_be_compact_and_capped
    outline = @app.get_outline(document_id: @document.id, depth: 10, max_nodes: 2, titles_only: true)

    assert_equal 2, outline[:returned_nodes]
    assert_equal true, outline[:truncated]
    node = outline[:root][:children].first
    refute node.key?(:content_start_char)
    refute node.key?(:passage_count)
    assert node[:node_id]
    assert node[:title]
  end

  def test_get_document_returns_shallow_title_outline
    document = @app.get_document(@document.id)

    outline = document[:outline]
    assert_equal 2, outline[:children].length
    assert outline[:children].all? { |child| !child.key?(:children) }
    refute outline[:children].first.key?(:content_start_char)
  end

  def test_markdown_toc_links_are_not_passages
    document = @app.ingest_text(
      <<~MARKDOWN,
        # Chapter One

        - [Chapter One](#chapter-one)
        - [Chapter Two](#chapter-two)

        Real content lives here.
      MARKDOWN
      title: "TOC",
      format: "markdown"
    )

    refute document.passages.any? { |passage| ["Chapter One", "Chapter Two"].include?(passage.text.strip) }
    assert document.passages.any? { |passage| passage.text.include?("Real content") }
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
