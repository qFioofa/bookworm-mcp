# frozen_string_literal: true

require_relative "test_helper"

class Fb2Test < Minitest::Test
  include FixtureHelpers

  def test_ingest_fb2_and_search_russian
    with_tmpdir do |dir|
      path = build_fb2(File.join(dir, "book.fb2"))
      app = Bookworm::App.new
      document = app.ingest_book(path)

      assert_equal "Test FB2", document.title
      assert_equal ["Ivan Petrov"], document.authors
      assert_equal "ru", document.language

      result = app.search(query: "убыточная акция", document_id: document.id)
      assert_operator result[:total], :>=, 1
      assert_includes result[:hits].first[:snippet], "убыточную акцию"
    end
  end

  def test_ingest_fb2_preserves_structure_and_footnotes
    with_tmpdir do |dir|
      path = build_fb2(File.join(dir, "book.fb2"))
      app = Bookworm::App.new
      document = app.ingest_book(path)

      assert_equal %w[Глава\ 1 Глава\ 2], document.nodes.select { |node| node.kind == "chapter" }.map(&:title)
      assert_includes document.nodes.map(&:title), "Раздел 1.1"
      assert_equal 1, document.footnotes.length
      assert_equal "1", document.footnotes.first.label
      assert_includes document.footnotes.first.text, "субъективная реакция"
      refute_includes document.full_text, "субъективная реакция"

      passage = document.passages.find { |item| item.text.include?("убыточную акцию") }
      refute_nil passage
      assert_equal ["n_1"], passage.footnote_ids
      assert_equal ["1"], document.footnotes_for(passage.footnote_ids).map(&:label)
    end
  end

  def test_outline_ranges_and_read_chapter
    with_tmpdir do |dir|
      path = build_fb2(File.join(dir, "book.fb2"))
      app = Bookworm::App.new
      document = app.ingest_book(path)

      outline = app.get_outline(document_id: document.id, depth: 10)
      chapter = outline[:root][:children].find { |node| node[:title] == "Глава 1" }
      refute_nil chapter
      assert_operator chapter[:content_end_char], :>, chapter[:end_char]
      assert_operator chapter[:content_start_char], :<, chapter[:content_end_char]
      assert_equal 1, chapter[:footnote_count]
      refute_nil chapter[:first_passage_id]

      result = app.read_chapter(document_id: document.id, node_id: chapter[:node_id])
      assert_equal chapter[:passage_count], result[:total]
      assert_equal chapter[:passage_count], result[:returned]
      assert_equal chapter[:content_start_char], result.dig(:range, :start_char)
      assert result[:passages].any? { |passage| passage[:footnotes].any? }
      assert_equal "Раздел 1.1", document.children_of(chapter[:node_id]).first.title
    end
  end

  def test_find_quote_prefers_books_and_reads_footnotes
    with_tmpdir do |dir|
      path = build_fb2(File.join(dir, "book.fb2"))
      app = Bookworm::App.new
      book = app.ingest_book(path)
      app.ingest_text("фраза только из пересказа", title: "Summary")

      book_quote = app.find_quote(quote: "инвестор отказывается продавать убыточную акцию", source: "book")
      assert_equal false, book_quote[:no_evidence]
      assert_equal "book", book_quote[:occurrences].first[:verification][:source]
      assert_equal book.id, book_quote[:occurrences].first[:citation][:document_id]

      footnote_quote = app.find_quote(quote: "субъективная реакция на убыток", document_id: book.id)
      assert_equal 1, footnote_quote[:total]
      occurrence = footnote_quote[:occurrences].first
      assert_equal "footnote", occurrence[:location]
      assert_equal "footnote", occurrence[:verification][:source]
      assert_equal "n_1", occurrence[:footnote_id]
      assert_equal true, occurrence[:verified]

      text_quote = app.find_quote(quote: "фраза только из пересказа")
      assert_equal "text", text_quote[:occurrences].first[:verification][:source]
      refute_nil text_quote[:occurrences].first[:warning]

      filtered = app.find_quote(quote: "фраза только из пересказа", source: "book")
      assert_equal true, filtered[:no_evidence]
      text_only = app.find_quote(quote: "фраза только из пересказа", source: "text")
      assert_equal false, text_only[:no_evidence]
    end
  end

  def test_find_quote_across_paragraph_boundary
    with_tmpdir do |dir|
      path = build_fb2(File.join(dir, "book.fb2"))
      app = Bookworm::App.new
      document = app.ingest_book(path)

      result = app.find_quote(quote: "Потери неприятны. Например", document_id: document.id)
      assert_equal 1, result[:total]
      occurrence = result[:occurrences].first
      assert_equal "book", occurrence[:verification][:source]
      assert_operator occurrence[:passage_ids].length, :>=, 1
    end
  end

  def test_ingest_is_deduplicated_with_stable_id
    with_tmpdir do |dir|
      path = build_fb2(File.join(dir, "book.fb2"))
      app = Bookworm::App.new

      first = app.ingest_book_result(path)
      second = app.ingest_book_result(path)

      assert_equal first.document.id, second.document.id
      assert_equal false, first.cached
      assert_equal true, second.cached
      assert_equal 1, app.list_documents[:total]
      assert_equal 1, app.stats.dig(:cache, :hits)

      text_first = app.ingest_text_result("Одинаковый текст для кэша", title: "Cache")
      text_second = app.ingest_text_result("Одинаковый текст для кэша", title: "Cache")
      assert_equal text_first.document.id, text_second.document.id
      assert_equal true, text_second.cached
    end
  end

  def test_ingest_windows_1251_fb2
    with_tmpdir do |dir|
      path = build_fb2_cp1251(File.join(dir, "book.fb2"))
      app = Bookworm::App.new
      document = app.ingest_book(path)

      assert_equal "Test FB2", document.title
      assert_includes document.full_text, "убыточную акцию"
      result = app.search(query: "убыточная акция", document_id: document.id)
      assert_operator result[:total], :>=, 1
    end
  end

  def test_ingest_resolves_nfc_and_decomposed_paths
    with_tmpdir do |dir|
      decomposed = "book\u0438\u0306.fb2"
      path = build_fb2(File.join(dir, decomposed))
      composed_path = File.join(dir, "book\u0439.fb2")

      assert_equal false, File.exist?(composed_path)
      document = Bookworm::App.new.ingest_book(composed_path)
      assert_equal "Test FB2", document.title
      assert_includes document.metadata.dig(:ingest, :path), decomposed
      assert_equal path, document.metadata.dig(:ingest, :path)
    end
  end

  def test_invalid_fb2_reports_parse_error
    with_tmpdir do |dir|
      path = File.join(dir, "broken.fb2")
      File.write(path, "<FictionBook><body></FictionBook>")

      error = assert_raises(Bookworm::UnsupportedFormatError) do
        Bookworm::App.new.ingest_book(path)
      end
      assert_equal "parse_error", error.details[:reason]
      assert_equal "parse", error.details[:stage]
    end
  end

  def test_ingest_book_replace_updates_same_path
    with_tmpdir do |dir|
      path = File.join(dir, "book.txt")
      File.write(path, "Версия один.")
      app = Bookworm::App.new
      app.ingest_book(path)

      File.write(path, "Версия два.")
      result = app.ingest_book_result(path, replace: true)

      assert_equal 1, app.list_documents[:total]
      assert_includes result.document.full_text, "Версия два."
      refute_includes result.document.full_text, "Версия один."
    end
  end

  def test_batch_ingest_and_per_document_stats
    with_tmpdir do |dir|
      path = build_fb2(File.join(dir, "book.fb2"))
      app = Bookworm::App.new

      result = app.ingest_books([path, "/tmp/bookworm-missing-batch.fb2"])
      assert_equal 2, result[:total]
      assert_equal 1, result[:succeeded]
      assert_equal 1, result[:failed]
      assert_equal "NOT_FOUND", result[:results].last.dig(:error, :code)

      document_id = result[:results].first.dig(:document, :document_id)
      stats = app.stats(document_id: document_id)
      assert_equal 1, stats[:documents]
      assert_equal stats[:document][:counts][:passages], stats[:passages]
    end
  end

  def test_ingest_zip_wrapped_fb2
    with_tmpdir do |dir|
      path = build_fb2_zip(File.join(dir, "book.fb2"))
      app = Bookworm::App.new
      document = app.ingest_book(path)

      assert_equal "Test FB2", document.title
      assert_includes document.full_text, "убыточную акцию"
      assert_equal 1, document.footnotes.length
    end
  end

  def test_ingest_fb2_zip_extension
    with_tmpdir do |dir|
      path = build_fb2_zip(File.join(dir, "book.fb2.zip"))
      app = Bookworm::App.new
      document = app.ingest_book(path)

      assert_includes document.full_text, "аналитик и тимлид"
    end
  end
end
