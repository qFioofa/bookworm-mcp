# frozen_string_literal: true

require "digest"

module Bookworm
  module Domain
    module Citation
      module_function

      def build(document:, passage:)
        {
          document_id: document.id,
          document_kind: document.kind,
          document_title: document.title,
          passage_id: passage.id,
          node_id: passage.node_id,
          chapter_path: passage.chapter_path,
          page: passage.page,
          paragraph_index: passage.paragraph_index,
          start_char: passage.start_char,
          end_char: passage.end_char,
          quote_hash: Digest::SHA256.hexdigest(passage.text),
          verified: true
        }
      end

      def build_span(document:, start_char:, end_char:, text:, node_id: nil, chapter_path: [], page: nil, passage_id: nil)
        {
          document_id: document.id,
          document_kind: document.kind,
          document_title: document.title,
          passage_id: passage_id,
          node_id: node_id,
          chapter_path: chapter_path || [],
          page: page,
          paragraph_index: 0,
          start_char: start_char,
          end_char: end_char,
          quote_hash: Digest::SHA256.hexdigest(text.to_s),
          verified: true
        }
      end

      def build_for_footnote(document:, footnote:, start_char:, end_char:, text:)
        build_span(
          document: document,
          start_char: start_char,
          end_char: end_char,
          text: text,
          node_id: footnote.node_id,
          chapter_path: [footnote.label].compact
        ).merge(
          footnote_id: footnote.id,
          footnote_label: footnote.label
        )
      end
    end
  end
end
