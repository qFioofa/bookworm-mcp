# frozen_string_literal: true

module Bookworm
  module Domain
    class Passage
      attr_reader :id, :document_id, :node_id, :ordinal, :text, :start_char,
                  :end_char, :page, :paragraph_index, :token_count, :chapter_path

      def initialize(
        id:, document_id:, node_id:, ordinal:, text:, start_char:, end_char:,
        page: nil, paragraph_index: 0, token_count: 0, chapter_path: []
      )
        @id = id
        @document_id = document_id
        @node_id = node_id
        @ordinal = ordinal
        @text = text
        @start_char = start_char
        @end_char = end_char
        @page = page
        @paragraph_index = paragraph_index
        @token_count = token_count
        @chapter_path = chapter_path
      end

      def local_length
        end_char - start_char
      end
    end
  end
end
