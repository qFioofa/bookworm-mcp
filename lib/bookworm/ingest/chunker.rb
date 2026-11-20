# frozen_string_literal: true

module Bookworm
  module Ingest
    module Chunker
      module_function

      def chunk_spans(text, max_chars)
        return [[0, text.length]] if text.empty? || text.length <= max_chars

        spans = []
        start = 0

        while start < text.length
          limit = [start + max_chars, text.length].min
          if limit >= text.length
            spans << [start, text.length]
            break
          end

          cut = text.rindex(/\s/, limit)
          cut = limit if cut.nil? || cut <= start

          sentence = text.rindex(/[.!?…]\s/, limit)
          if sentence && sentence > start + (max_chars / 2)
            cut = sentence + 1
          end

          cut = text.length if cut <= start
          spans << [start, cut]
          start = cut
          start += 1 while start < text.length && text[start].match?(/\s/)
        end

        spans.empty? ? [[0, text.length]] : spans
      end
    end
  end
end
