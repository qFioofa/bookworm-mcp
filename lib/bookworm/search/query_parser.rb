# frozen_string_literal: true

module Bookworm
  module Search
    Query = Struct.new(:raw, :terms, :required, :excluded, :phrases, keyword_init: true)

    module QueryParser
      TERM_PATTERN = /([+-]?)([\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*)/u

      module_function

      def parse(raw)
        query = raw.to_s.strip
        raise ValidationError.new("Query must not be empty") if query.empty?

        phrases = query.scan(/"([^"]+)"/).flatten.map(&:strip).reject(&:empty?)
        remaining = query.gsub(/"[^"]*"/, " ")

        terms = []
        required = []
        excluded = []

        remaining.to_enum(:scan, TERM_PATTERN).each do
          match = Regexp.last_match
          prefix = match[1]
          term = Tokenizer.normalize_token(match[2])
          next if term.empty?

          case prefix
          when "+"
            required << term
          when "-"
            excluded << term
          else
            terms << term
          end
        end

        terms = (terms + required).uniq
        if terms.empty? && phrases.empty?
          terms = Tokenizer.tokenize(query, keep_stopwords: true).map(&:text).uniq
        end

        if terms.empty? && phrases.empty?
          raise ValidationError.new("Query contains no searchable terms")
        end

        Query.new(
          raw: query,
          terms: terms,
          required: required.uniq,
          excluded: excluded.uniq,
          phrases: phrases
        )
      end
    end
  end
end
