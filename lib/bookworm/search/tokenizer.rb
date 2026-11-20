# frozen_string_literal: true

require "set"

module Bookworm
  module Search
    Token = Struct.new(:raw, :text, :stem, :start, :end, keyword_init: true)

    module Tokenizer
      TOKEN_PATTERN = /[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*/u

      STOPWORD_SET = LanguageData.stopwords.to_set.freeze

      module_function

      def tokenize(text, keep_stopwords: false)
        tokens = []
        text.to_s.to_enum(:scan, TOKEN_PATTERN).each do
          match = Regexp.last_match
          raw = match[0]
          normalized = normalize_token(raw)
          next if !keep_stopwords && STOPWORD_SET.include?(normalized)

          tokens << Token.new(
            raw: raw,
            text: normalized,
            stem: Stemmer.stem(normalized),
            start: match.begin(0),
            end: match.end(0)
          )
        end
        tokens
      end

      def terms(text)
        tokenize(text).map(&:stem)
      end

      def phrase_terms(text)
        tokenize(text, keep_stopwords: true).map(&:text)
      end

      def normalize_token(text)
        text.to_s.unicode_normalize(:nfkc).downcase.tr("ё", "е")
      end

      def stopword?(text)
        STOPWORD_SET.include?(normalize_token(text))
      end
    end
  end
end
