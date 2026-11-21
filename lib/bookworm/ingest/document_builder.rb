# frozen_string_literal: true

module Bookworm
  module Ingest
    class DocumentBuilder
      attr_reader :config

      def initialize(config:)
        @config = config
      end

      def build(draft, kind:, source_hash:, ttl_seconds: nil)
        document_id = build_document_id(kind, source_hash)
        root = Domain::Node.new(
          id: "#{document_id}:n0",
          document_id: document_id,
          kind: kind == "text" ? "fragment" : "document",
          title: draft.title,
          level: 0,
          ordinal: 0
        )

        nodes = [root]
        passages = []
        full_text = +""
        heading_stack = [{ level: 0, node: root, path: [] }]
        current_node = root
        paragraph_index = 0
        block_index = 0

        draft.blocks.each do |block|
          block_index += 1
          text = normalize_block_text(block)
          next if text.empty?

          block_start = full_text.empty? ? 0 : full_text.length + 2
          full_text << "\n\n" unless full_text.empty?
          full_text << text
          block_end = full_text.length

          if block.heading?
            level = block.level || 1
            level = 1 if block.type == :chapter

            heading_stack.pop while heading_stack.length > 1 && heading_stack.last[:level] >= level
            parent = heading_stack.last[:node]
            path = heading_stack.last[:path] + [text]

            node = Domain::Node.new(
              id: "#{document_id}:n#{nodes.length}",
              document_id: document_id,
              parent_id: parent.id,
              kind: block.type == :chapter ? "chapter" : "section",
              title: text,
              level: level,
              ordinal: block_index,
              page_start: block.page,
              page_end: block.page,
              start_char: block_start,
              end_char: block_end
            )
            nodes << node
            heading_stack << { level: level, node: node, path: path }
            current_node = node
            next
          end

          chapter_path = heading_stack.last[:path].dup
          Chunker.chunk_spans(text, config.max_passage_chars).each do |local_start, local_end|
            passage_text = text[local_start...local_end]
            next if passage_text.strip.empty?

            passages << Domain::Passage.new(
              id: "#{document_id}:p#{passages.length + 1}",
              document_id: document_id,
              node_id: current_node.id,
              ordinal: passages.length + 1,
              text: passage_text,
              start_char: block_start + local_start,
              end_char: block_start + local_end,
              page: block.page,
              paragraph_index: paragraph_index,
              token_count: estimate_tokens(passage_text),
              chapter_path: chapter_path,
              footnote_ids: block.footnote_ids
            )
            paragraph_index += 1
          end
        end

        Domain::Document.new(
          id: document_id,
          kind: kind,
          title: draft.title,
          authors: Array(draft.authors).compact,
          language: draft.language || Util::Text.detect_language(full_text),
          format: draft.format,
          source_hash: source_hash,
          created_at: Time.now,
          expires_at: ttl_seconds ? Time.now + ttl_seconds : nil,
          nodes: nodes,
          passages: passages,
          footnotes: draft.footnotes || [],
          metadata: draft.metadata || {},
          full_text: full_text
        )
      end

      private

      def build_document_id(kind, source_hash)
        prefix = kind == "text" ? "txt" : "doc"
        "#{prefix}_#{source_hash[0, 16]}"
      end

      def normalize_block_text(block)
        text = block.text.to_s
        text = Util::Text.normalize_newlines(text)
        text = Util::Text.collapse_whitespace(text) unless block.type == :code
        text.strip
      end

      def estimate_tokens(text)
        [(text.length / 4.0).ceil, 1].max
      end
    end
  end
end
