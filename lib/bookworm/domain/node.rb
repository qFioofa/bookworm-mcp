# frozen_string_literal: true

module Bookworm
  module Domain
    class Node
      attr_reader :id, :document_id, :parent_id, :kind, :title, :level,
                  :ordinal, :page_start, :page_end, :start_char, :end_char

      def initialize(
        id:, document_id:, parent_id: nil, kind: "section", title: nil,
        level: 1, ordinal: 0, page_start: nil, page_end: nil,
        start_char: nil, end_char: nil
      )
        @id = id
        @document_id = document_id
        @parent_id = parent_id
        @kind = kind
        @title = title
        @level = level
        @ordinal = ordinal
        @page_start = page_start
        @page_end = page_end
        @start_char = start_char
        @end_char = end_char
      end

      def to_h
        {
          node_id: id,
          parent_id: parent_id,
          kind: kind,
          title: title,
          level: level,
          page_start: page_start,
          page_end: page_end,
          start_char: start_char,
          end_char: end_char
        }
      end
    end
  end
end
