# frozen_string_literal: true

module Bookworm
  module Domain
    class Footnote
      attr_reader :id, :label, :text, :node_id

      def initialize(id:, label:, text:, node_id: nil)
        @id = id
        @label = label
        @text = text
        @node_id = node_id
      end

      def to_h(include_text: true)
        payload = {
          footnote_id: id,
          label: label,
          node_id: node_id
        }
        payload[:text] = text if include_text
        payload
      end
    end
  end
end
