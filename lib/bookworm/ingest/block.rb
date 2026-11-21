# frozen_string_literal: true

module Bookworm
  module Ingest
    Block = Struct.new(:type, :text, :level, :page, :title, :footnote_ids, keyword_init: true) do
      def heading?
        type == :chapter || type == :heading
      end
    end
  end
end
