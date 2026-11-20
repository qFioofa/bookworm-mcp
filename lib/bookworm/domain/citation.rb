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
    end
  end
end
