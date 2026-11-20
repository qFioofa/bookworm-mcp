# frozen_string_literal: true

require "set"

module Bookworm
  module Search
    class Index
      attr_reader :documents, :passages, :postings, :doc_lengths, :avgdl,
                  :passage_tokens, :passage_phrase_tokens, :node_title_stems,
                  :document_title_stems

      def initialize(documents)
        @documents = documents.to_h { |document| [document.id, document] }
        @passages = {}
        @postings = Hash.new { |hash, key| hash[key] = {} }
        @doc_lengths = {}
        @passage_tokens = {}
        @passage_phrase_tokens = {}
        @node_title_stems = {}
        @document_title_stems = {}

        documents.each do |document|
          @document_title_stems[document.id] = stems_for(document.title)

          document.nodes.each do |node|
            @node_title_stems[node.id] = stems_for(node.title)
          end

          document.passages.each do |passage|
            @passages[passage.id] = passage
            tokens = Tokenizer.tokenize(passage.text)
            terms = tokens.map(&:stem)
            @doc_lengths[passage.id] = terms.length
            terms.tally.each { |term, frequency| @postings[term][passage.id] = frequency }
            @passage_tokens[passage.id] = Tokenizer.tokenize(passage.text, keep_stopwords: true).map(&:text).to_set
            @passage_phrase_tokens[passage.id] = Tokenizer.tokenize(passage.text, keep_stopwords: true).map(&:text)
          end
        end

        total = @doc_lengths.values.sum
        @avgdl = @doc_lengths.empty? ? 1.0 : [total.to_f / @doc_lengths.length, 1.0].max
      end

      def bm25(term, passage_id, k1: 1.2, b: 0.75)
        frequency = @postings[term]&.[](passage_id)
        return 0.0 unless frequency

        document_frequency = @postings[term].length
        idf = Math.log(1.0 + (@doc_lengths.length - document_frequency + 0.5) / (document_frequency + 0.5))
        length = @doc_lengths[passage_id]
        denominator = frequency + k1 * (1.0 - b + b * length / @avgdl)
        idf * (frequency * (k1 + 1.0)) / denominator
      end

      def title_stems_for(passage)
        node_stems = @node_title_stems[passage.node_id] || Set.new
        document_stems = @document_title_stems[passage.document_id] || Set.new
        node_stems | document_stems
      end

      private

      def stems_for(text)
        Tokenizer.tokenize(text).map(&:stem).to_set
      end
    end
  end
end
