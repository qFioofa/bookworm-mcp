# frozen_string_literal: true

require_relative "test_helper"

class SearchTest < Minitest::Test
  def setup
    @app = Bookworm::App.new
    @document = @app.ingest_text(
      <<~TEXT,
        Loss aversion is a cognitive bias. People dislike losses more than they like gains.

        For example, an investor may refuse to sell a losing stock. This is a classic case of loss aversion.

        Risk seeking can appear when a person faces certain loss.
      TEXT
      title: "Loss aversion",
      format: "plain"
    )
  end

  def test_search_returns_ranked_citations
    result = @app.search(query: "loss aversion", k: 5, include_text: true)

    assert_equal 3, result[:total]
    assert_equal 3, result[:returned]
    assert_equal "Loss aversion", result[:hits].first[:citation][:document_title]
    assert_equal true, result[:hits].first[:citation][:verified]
    assert_equal 1.0, result[:hits].first[:score]
    assert_includes result[:hits].first[:score_breakdown].keys, :lexical
    assert_includes result[:hits].first[:matched_terms], "loss"
    refute_empty result[:hits].first[:highlights]
  end

  def test_compact_search_output
    result = @app.search(query: "loss", k: 2, verbosity: "compact", include_breakdown: false)

    assert_equal "lexical", result[:retrieval]
    assert_equal false, result[:semantic]
    hit = result[:hits].first
    refute hit.key?(:highlights)
    refute hit.key?(:score_breakdown)
    refute hit.key?(:matched_terms)
    assert hit[:citation]
    assert hit[:snippet]
  end

  def test_phrase_search
    result = @app.search(query: '"loss aversion"', k: 5)
    top = result[:hits].first

    assert_equal "phrase", top[:match_type]
    assert_operator top[:score_breakdown][:phrase], :>, 0
  end

  def test_phrase_search_falls_back_to_relaxed_terms
    result = @app.search(query: '"loss bias"', k: 5)

    assert_equal "relaxed_phrase", result[:fallback]
    assert_operator result[:total], :>=, 1
    assert result[:hits].any? { |hit| hit[:snippet].downcase.include?("loss") }
  end

  def test_required_and_excluded_terms
    result = @app.search(query: "loss -gains", k: 10)

    assert result[:hits].all? { |hit| !hit[:snippet].downcase.include?("gains") }
    assert result[:hits].any? { |hit| hit[:snippet].downcase.include?("loss") }
  end

  def test_pagination
    first = @app.search(query: "loss", k: 1)
    assert_equal 1, first[:returned]
    assert first[:next_cursor]

    second = @app.search(query: "loss", k: 1, cursor: first[:next_cursor])
    assert_equal 1, second[:returned]
    refute_equal first[:hits].first[:passage_id], second[:hits].first[:passage_id]
  end

  def test_fuzzy_search_tolerates_typos
    result = @app.search(query: "biass", k: 5)

    assert_operator result[:total], :>=, 1
    assert_equal "fuzzy", result[:hits].first[:match_type]
    assert_includes result[:hits].first[:snippet].downcase, "bias"
  end

  def test_find_quote_exact
    result = @app.find_quote(quote: "refuse to sell a losing stock")

    assert_equal 1, result[:total]
    assert_equal false, result[:no_evidence]
    occurrence = result[:occurrences].first
    assert_equal true, occurrence[:verified]
    assert_equal "exact", occurrence[:match_type]
    assert_equal "refuse to sell a losing stock", occurrence[:matched_text]
  end

  def test_find_quote_no_evidence
    result = @app.find_quote(quote: "the moon is made of cheese")

    assert_equal 0, result[:total]
    assert_equal true, result[:no_evidence]
  end

  def test_read_passage_with_neighbors
    passage_id = @document.passages.first.id
    result = @app.read_passage(passage_id: passage_id, before: 0, after: 1)

    assert_equal passage_id, result[:passage][:passage_id]
    assert_equal 1, result[:after].length
    assert_equal 0, result[:before].length
  end

  def test_read_passage_without_neighbors
    passage_id = @document.passages.first.id
    result = @app.read_passage(passage_id: passage_id, before: 0, after: 0)

    assert_equal [], result[:before]
    assert_equal [], result[:after]
  end

  def test_outline_for_text
    outline = @app.get_outline(document_id: @document.id)

    assert_equal @document.id, outline[:document][:document_id]
    assert_equal 3, outline[:root][:passage_count]
  end

  def test_long_inline_text_is_chunked
    text = (["integration"] * 1200).join(" ")
    document = @app.ingest_text(text, title: "Long")

    assert_operator document.passages.length, :>, 1
    assert document.passages.all? { |passage| passage.text.length <= 1400 }
  end

  def test_ingest_text_rejects_placeholder
    error = assert_raises(Bookworm::ValidationError) do
      @app.ingest_text("$(placeholder)")
    end

    assert_equal "placeholder", error.details[:reason]
  end

  def test_ingest_text_reads_source_path
    Dir.mktmpdir("bookworm-text") do |dir|
      path = File.join(dir, "notes.md")
      File.write(path, "# Heading\n\nA file based fragment.")

      document = @app.ingest_text(source_path: path)

      assert_equal "notes", document.title
      assert_includes document.full_text, "A file based fragment."
      assert_equal "markdown", document.format
      assert_operator document.passages.length, :>=, 1
    end
  end

  def test_ingest_text_missing_source_path_reports_file_not_found
    error = assert_raises(Bookworm::NotFoundError) do
      @app.ingest_text(source_path: "/tmp/bookworm-missing-text-file.txt")
    end

    assert_equal "file_not_found", error.details[:reason]
    assert_includes error.details[:hint], "Docker"
  end

  def test_ingest_text_rejects_non_text_source_path
    Dir.mktmpdir("bookworm-text") do |dir|
      path = File.join(dir, "book.fb2")
      File.write(path, "<FictionBook/>")

      error = assert_raises(Bookworm::ValidationError) do
        @app.ingest_text(source_path: path)
      end

      assert_equal "non_text_source", error.details[:reason]
    end
  end

  def test_ingest_text_rejects_non_http_source_url
    error = assert_raises(Bookworm::ValidationError) do
      @app.ingest_text(source_url: "file:///etc/passwd")
    end

    assert_equal "unsupported_url", error.details[:reason]
  end
end
