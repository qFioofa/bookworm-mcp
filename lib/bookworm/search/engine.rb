# frozen_string_literal: true

require "base64"
require "json"
require "set"

module Bookworm
  module Search
    class Engine
      MODES = %w[smart lexical exact fuzzy].freeze

      def initialize(store:, config:)
        @store = store
        @config = config
        @index = nil
        @index_key = nil
      end

      def search(
        query:,
        document_id: nil,
        mode: "smart",
        k: 10,
        cursor: nil,
        include_text: false,
        filters: {},
        max_tokens: nil,
        verbosity: "full",
        include_breakdown: true
      )
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @store.remove_expired!
        mode = normalize_mode(mode)
        verbosity = normalize_verbosity(verbosity)
        filters = (filters || {}).transform_keys(&:to_sym)
        document_id = document_id.to_s unless document_id.nil?
        document_id = nil if document_id&.empty?

        query_object = QueryParser.parse(query)
        documents = scope_documents(document_id, filters)
        if document_id && documents.empty?
          raise NotFoundError.new("Document not found", details: { document_id: document_id })
        end

        if documents.empty?
          return empty_result(query_object, mode, started, verbosity)
        end

        index = index_for(documents)
        ids = candidate_ids(index, query_object, mode)
        results = collect_results(ids, index, query_object, mode, filters)
        fallback = nil

        if results.empty? && mode == "smart"
          relaxed = relaxed_query(query_object)
          if relaxed
            relaxed_ids = candidate_ids(index, relaxed, mode)
            results = collect_results(relaxed_ids, index, relaxed, mode, filters)
            fallback = "relaxed_phrase" unless results.empty?
          end
        end

        results.sort_by! { |result| [-result[:raw], result[:passage].ordinal] }
        max_raw = results.map { |result| result[:raw] }.max || 0.0
        results.each do |result|
          result[:score] = max_raw.positive? ? (result[:raw] / max_raw).round(4) : 0.0
        end

        limit = [[k.to_i, 1].max, @config.max_results].min
        offset = decode_cursor(cursor)
        page = results[offset, limit] || []
        next_cursor = offset + limit < results.length ? encode_cursor(offset + limit) : nil

        hits = page.map.with_index(1) do |result, index_number|
          build_hit(
            result,
            offset + index_number,
            query_object,
            include_text,
            max_tokens,
            verbosity: verbosity,
            include_breakdown: include_breakdown
          )
        end

        {
          query: query_object.raw,
          mode: mode,
          retrieval: "lexical",
          semantic: false,
          fallback: fallback,
          verbosity: verbosity,
          total: results.length,
          returned: hits.length,
          limit: limit,
          next_cursor: next_cursor,
          hits: hits,
          took_ms: elapsed_ms(started)
        }
      end

      private

      def normalize_mode(mode)
        value = (mode || "smart").to_s
        return value if MODES.include?(value)

        raise ValidationError.new(
          "Unknown search mode: #{value}",
          details: { supported: MODES }
        )
      end

      def normalize_verbosity(verbosity)
        value = (verbosity || "full").to_s
        return value if %w[full compact].include?(value)

        raise ValidationError.new(
          "Unknown verbosity: #{value}",
          details: { supported: %w[full compact] }
        )
      end

      def scope_documents(document_id, filters)
        documents = @store.documents
        documents = documents.select { |document| document.id == document_id } if document_id
        if filters[:kind]
          documents = documents.select { |document| document.kind == filters[:kind].to_s }
        end
        if filters[:language]
          documents = documents.select { |document| document.language == filters[:language].to_s }
        end
        documents
      end

      def index_for(documents)
        key = [@store.version, documents.map(&:id).sort.join("|")]
        if @index.nil? || @index_key != key
          @index = Index.new(documents)
          @index_key = key
        end
        @index
      end

      def candidate_ids(index, query, mode)
        return index.passages.keys if %w[exact fuzzy].include?(mode)

        ids = Set.new
        query.terms.each do |term|
          stem = Stemmer.stem(term)
          ids.merge(index.postings[stem].keys) if index.postings.key?(stem)
        end
        query.phrases.each do |phrase|
          first = Tokenizer.terms(phrase).first
          ids.merge(index.postings[first].keys) if first && index.postings.key?(first)
        end

        return ids.to_a unless ids.empty?
        return [] if mode == "lexical"

        index.passages.keys
      end

      def collect_results(ids, index, query, mode, filters)
        ids.filter_map do |passage_id|
          passage = index.passages[passage_id]
          next unless passage

          document = index.documents[passage.document_id]
          evaluate(passage, document, index, query, mode, filters)
        end
      end

      def relaxed_query(query)
        return nil if query.phrases.empty?

        phrase_terms = query.phrases.flat_map do |phrase|
          Tokenizer.tokenize(phrase).map(&:text)
        end
        terms = (query.terms + phrase_terms).uniq
        return nil if terms.empty?

        Query.new(
          raw: query.raw,
          terms: terms,
          required: query.required,
          excluded: query.excluded,
          phrases: []
        )
      end

      def evaluate(passage, document, index, query, mode, filters)
        return nil unless passage_matches_filters?(passage, document, filters)
        return nil if query.excluded.any? { |term| term_present?(term, passage, index) }

        phrase_tokens = query.phrases.map { |phrase| Tokenizer.phrase_terms(phrase) }.reject(&:empty?)
        phrase_hits = phrase_tokens.count do |tokens|
          contains_sequence?(index.passage_phrase_tokens[passage.id] || [], tokens)
        end
        return nil if phrase_tokens.any? && phrase_hits < phrase_tokens.length

        if mode == "exact"
          exact_query = query.phrases.first || query.raw.gsub(/"/, "")
          occurrences = exact_occurrences(passage.text, exact_query)
          return nil if occurrences.zero?

          return {
            passage: passage,
            raw: 1.0 + (occurrences * 0.1),
            bm25: 0.0,
            phrase: occurrences.to_f,
            title: 0.0,
            exact: 1.0,
            fuzzy: 0.0,
            coverage: 1.0,
            matched_terms: query.terms,
            match_type: "exact"
          }
        end

        tokens = index.passage_tokens[passage.id] || Set.new
        term_stems = query.terms.map { |term| Stemmer.stem(term) }.uniq
        matched = []
        bm25 = 0.0
        exact_boost = 0.0

        query.terms.each do |term|
          stem = Stemmer.stem(term)
          bm25 += index.bm25(stem, passage.id)
          if index.postings[stem]&.key?(passage.id)
            matched << term
          elsif tokens.include?(Tokenizer.normalize_token(term))
            matched << term
            exact_boost += 0.25
          end
        end

        required_ok = query.required.all? { |term| term_present?(term, passage, index) }
        return nil unless required_ok

        title_stems = index.title_stems_for(passage)
        title_boost = term_stems.any? { |stem| title_stems.include?(stem) } ? 0.8 : 0.0

        fuzzy = 0.0
        if mode == "fuzzy" || (mode == "smart" && matched.empty? && phrase_hits.zero?)
          fuzzy = fuzzy_similarity(query.raw, passage, index)
          return nil if fuzzy < 0.2
        end

        phrase_score = phrase_hits * 2.5
        coverage = if query.terms.empty?
                     phrase_hits.positive? ? 1.0 : 0.0
                   else
                     matched.uniq.length.to_f / query.terms.length
                   end

        raw = bm25 + phrase_score + title_boost + exact_boost + (fuzzy * 1.5)
        raw *= (0.6 + 0.4 * coverage) if query.terms.any?
        return nil if raw <= 0.0

        match_type = if fuzzy.positive? && matched.empty?
                       "fuzzy"
                     elsif phrase_hits.positive?
                       "phrase"
                     else
                       "lexical"
                     end

        {
          passage: passage,
          raw: raw,
          bm25: bm25,
          phrase: phrase_score,
          title: title_boost,
          exact: exact_boost,
          fuzzy: fuzzy,
          coverage: coverage,
          matched_terms: matched.uniq,
          match_type: match_type
        }
      end

      def passage_matches_filters?(passage, document, filters)
        if filters[:node_id]
          node_id = filters[:node_id].to_s
          return false unless document.descendant_node_ids(node_id).include?(passage.node_id)
        end
        return false if filters[:page_min] && (passage.page.nil? || passage.page < filters[:page_min].to_i)
        return false if filters[:page_max] && (passage.page.nil? || passage.page > filters[:page_max].to_i)

        true
      end

      def term_present?(term, passage, index)
        normalized = Tokenizer.normalize_token(term)
        stem = Stemmer.stem(normalized)
        return true if index.postings[stem]&.key?(passage.id)

        (index.passage_tokens[passage.id] || Set.new).include?(normalized)
      end

      def contains_sequence?(sequence, tokens)
        return false if tokens.empty? || sequence.empty?
        return sequence.include?(tokens.first) if tokens.length == 1

        sequence.each_cons(tokens.length).any? { |window| window == tokens }
      end

      def fuzzy_similarity(query, passage, index)
        query_terms = Tokenizer.tokenize(query, keep_stopwords: true).map(&:text)
        passage_tokens = index.passage_phrase_tokens[passage.id] || []
        whole = Trigram.similarity(query, passage.text)

        token_score = if query_terms.empty? || passage_tokens.empty?
                        0.0
                      else
                        scores = query_terms.map do |query_term|
                          passage_tokens.map { |passage_token| Trigram.similarity(query_term, passage_token) }.max || 0.0
                        end
                        scores.sum / scores.length
                      end

        [whole, token_score].max
      end

      def exact_occurrences(text, query)
        needle = query.to_s.downcase
        return 0 if needle.empty?

        haystack = text.to_s.downcase
        count = 0
        position = 0
        while (index = haystack.index(needle, position))
          count += 1
          position = index + [needle.length, 1].max
        end
        count
      end

      def build_hit(result, rank, query, include_text, max_tokens, verbosity: "full", include_breakdown: true)
        passage = result[:passage]
        document = @store.find_document(passage.document_id)
        terms = snippet_terms(query)
        snippet, highlights = Snippet.build(
          passage.text,
          terms: terms,
          max_chars: @config.snippet_chars
        )

        hit = {
          rank: rank,
          passage_id: passage.id,
          citation: Domain::Citation.build(document: document, passage: passage),
          snippet: snippet,
          score: result[:score],
          match_type: result[:match_type]
        }

        if verbosity == "full"
          hit[:highlights] = highlights
          hit[:raw_score] = result[:raw].round(4)
          hit[:matched_terms] = result[:matched_terms]
          hit[:coverage] = result[:coverage].round(3)
          hit[:entity_ids] = []
        end

        if include_breakdown && verbosity == "full"
          hit[:score_breakdown] = {
            lexical: result[:bm25].round(4),
            vector: 0.0,
            phrase: result[:phrase].round(4),
            title: result[:title].round(4),
            exact: result[:exact].round(4),
            fuzzy: result[:fuzzy].round(4),
            fused: result[:raw].round(4)
          }
        end

        if include_text
          text = passage.text
          if max_tokens
            limit = max_tokens.to_i * 4
            if text.length > limit
              text = text[0...limit]
              hit[:text_truncated] = true
            end
          end
          hit[:text] = text
        end

        hit
      end

      def snippet_terms(query)
        terms = query.terms.dup
        query.phrases.each do |phrase|
          terms.concat(Tokenizer.tokenize(phrase, keep_stopwords: true).map(&:text))
        end
        terms << query.raw if terms.empty?
        terms.uniq
      end

      def empty_result(query, mode, started, verbosity)
        {
          query: query.raw,
          mode: mode,
          retrieval: "lexical",
          semantic: false,
          fallback: nil,
          verbosity: verbosity,
          total: 0,
          returned: 0,
          limit: 0,
          next_cursor: nil,
          hits: [],
          took_ms: elapsed_ms(started)
        }
      end

      def elapsed_ms(started)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
      end

      def encode_cursor(offset)
        Base64.urlsafe_encode64({ offset: offset }.to_json, padding: false)
      end

      def decode_cursor(cursor)
        return 0 if cursor.nil? || cursor.to_s.empty?

        payload = JSON.parse(Base64.urlsafe_decode64(cursor.to_s))
        [payload.fetch("offset", 0).to_i, 0].max
      rescue StandardError
        0
      end
    end
  end
end
