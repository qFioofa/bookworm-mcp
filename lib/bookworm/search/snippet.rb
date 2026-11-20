# frozen_string_literal: true

module Bookworm
  module Search
    module Snippet
      module_function

      def build(text, terms:, max_chars: 320)
        source = text.to_s
        downcased = source.downcase
        normalized_terms = terms.map { |term| Util::Text.normalize_for_match(term) }.reject(&:empty?).uniq

        first_index = normalized_terms.filter_map { |term| downcased.index(term) }.min
        first_index ||= 0

        start = [first_index - (max_chars / 3), 0].max
        finish = [start + max_chars, source.length].min
        start = source.rindex(/\s/, start) || start if start.positive?
        finish = source.index(/\s/, finish) || finish if finish < source.length

        snippet = source[start...finish].to_s.strip
        prefix = start.positive? ? "…" : ""
        suffix = finish < source.length ? "…" : ""
        snippet = "#{prefix}#{snippet}#{suffix}"

        highlights = find_highlights(snippet, normalized_terms, offset: prefix.length)
        [snippet, highlights]
      end

      def find_highlights(snippet, terms, offset: 0)
        haystack = snippet.downcase
        highlights = []

        terms.each do |term|
          position = 0
          loop do
            index = haystack.index(term, position)
            break unless index

            highlights << {
              start: index + offset,
              end: index + offset + term.length,
              term: term
            }
            position = index + [term.length, 1].max
          end
        end

        highlights
          .sort_by { |highlight| [highlight[:start], highlight[:end]] }
          .each_with_object([]) do |highlight, result|
            previous = result.last
            if previous && highlight[:start] < previous[:end]
              previous[:end] = [previous[:end], highlight[:end]].max
            else
              result << highlight
            end
          end
      end
    end
  end
end
