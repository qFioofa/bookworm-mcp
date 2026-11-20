# frozen_string_literal: true

require_relative "test_helper"

class EpubTest < Minitest::Test
  include FixtureHelpers

  def test_ingest_epub
    with_tmpdir do |dir|
      path = build_epub(File.join(dir, "book.epub"))
      app = Bookworm::App.new
      document = app.ingest_book(path)

      assert_equal "Test Book", document.title
      assert_equal ["Jane Doe"], document.authors
      assert_equal "en", document.language
      assert_equal "epub", document.format
      assert_equal 2, document.nodes.count { |node| node.kind == "chapter" }

      outline = app.get_outline(document_id: document.id)
      assert_equal ["Chapter One", "Chapter Two"], outline[:root][:children].map { |child| child[:title] }

      result = app.search(query: "losing stock", document_id: document.id)
      assert_equal 1, result[:total]
      assert_equal ["Chapter Two"], result[:hits].first[:citation][:chapter_path]
    end
  end
end
