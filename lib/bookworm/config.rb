# frozen_string_literal: true

module Bookworm
  class Config
    attr_reader :max_inline_bytes, :default_ttl, :max_passage_chars,
                :max_results, :snippet_chars, :allowed_roots

    def initialize(
      max_inline_bytes: 1_048_576,
      default_ttl: 3600,
      max_passage_chars: 1400,
      max_results: 50,
      snippet_chars: 320,
      allowed_roots: nil
    )
      @max_inline_bytes = max_inline_bytes
      @default_ttl = default_ttl
      @max_passage_chars = max_passage_chars
      @max_results = max_results
      @snippet_chars = snippet_chars
      @allowed_roots = allowed_roots
    end
  end
end
