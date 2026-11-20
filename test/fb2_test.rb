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
end
