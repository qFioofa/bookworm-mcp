# frozen_string_literal: true

require "digest"

module Bookworm
  module Ingest
    class Pipeline
      def initialize(store:, config:)
        @store = store
        @config = config
        @builder = DocumentBuilder.new(config: config)
      end

      def ingest_book(path, title: nil)
        expanded = File.expand_path(path.to_s)
        raise NotFoundError.new("Book file not found", details: { path: expanded }) unless File.file?(expanded)

        bytes = File.binread(expanded)
        source_hash = Digest::SHA256.hexdigest(bytes)
        existing = @store.find_by_source_hash(source_hash)
        return existing if existing && !existing.expired?

        adapter = Adapters::Registry.for_path(expanded)
        draft = adapter.parse(expanded)
        draft.title = title if title && !title.to_s.strip.empty?
        document = @builder.build(
          draft,
          kind: "book",
          source_hash: source_hash,
          ttl_seconds: nil
        )
        @store.add(document)
      end

      def ingest_text(text, title: nil, format: "plain", language: nil, ttl_seconds: nil)
        content = text.to_s
        raise ValidationError.new("Text must not be empty") if content.strip.empty?

        bytes = content.bytesize
        if bytes > @config.max_inline_bytes
          raise TextTooLargeError.new(
            "Inline text is too large",
            details: {
              bytes: bytes,
              max_bytes: @config.max_inline_bytes,
              hint: "write the text to a file and use ingest_book"
            }
          )
        end

        format = (format || "plain").to_s
        unless %w[plain markdown].include?(format)
          raise ValidationError.new(
            "Unsupported text format",
            details: { format: format, supported: %w[plain markdown] }
          )
        end

        source_hash = Digest::SHA256.hexdigest("#{format}\0#{content}")
        existing = @store.find_by_source_hash(source_hash)
        return existing if existing && !existing.expired?

        ttl = ttl_seconds.nil? ? @config.default_ttl : ttl_seconds.to_i
        ttl = nil if ttl <= 0

        draft = Adapters::Text.parse(
          content,
          title: title,
          format: format,
          language: language
        )
        document = @builder.build(
          draft,
          kind: "text",
          source_hash: source_hash,
          ttl_seconds: ttl
        )
        @store.add(document)
      end

      def remove(document_id)
        document = @store.find_document(document_id)
        raise NotFoundError.new("Document not found", details: { document_id: document_id }) unless document

        @store.remove(document_id)
        document
      end
    end
  end
end
