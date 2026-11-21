# frozen_string_literal: true

require "digest"
require "net/http"
require "openssl"
require "uri"

module Bookworm
  module Ingest
    Result = Struct.new(:document, :cached, keyword_init: true)

    class Pipeline
      PLACEHOLDER_PATTERNS = [
        /\A\s*\$\([^)]*\)\s*\z/,
        /\A\s*\$\{[^}]*\}\s*\z/,
        /\A\s*\{\{[^}]*\}\}\s*\z/,
        /\A\s*<[^<>]*>\s*\z/,
        /\A\s*\[[^\[\]]*\]\s*\z/,
        /\A\s*(?:todo|tbd|placeholder|replace me|nothing|none|null|undefined|n\/a)\s*\z/i
      ].freeze
      MAX_REDIRECTS = 3
      DOCKER_PATH_HINT = "When running in Docker, mount the host directory " \
                         "(for example -v /host/books:/books:ro) and pass the container path."

      attr_reader :cache_hits, :cache_misses

      def initialize(store:, config:)
        @store = store
        @config = config
        @builder = DocumentBuilder.new(config: config)
        @cache_hits = 0
        @cache_misses = 0
      end

      def ingest_book(path, title: nil, replace: false)
        expanded = resolve_path(path)
        unless File.file?(expanded)
          raise NotFoundError.new(
            "Book file not found",
            details: {
              path: expanded,
              requested_path: path.to_s,
              reason: "file_not_found",
              hint: DOCKER_PATH_HINT
            }
          )
        end

        bytes = File.binread(expanded)
        source_hash = Digest::SHA256.hexdigest(bytes)
        existing = @store.find_by_source_hash(source_hash)
        if existing && !existing.expired?
          @cache_hits += 1
          return Result.new(document: existing, cached: true)
        end

        @cache_misses += 1
        remove_documents_for_path(expanded) if replace
        adapter = Adapters::Registry.for_path(expanded)
        draft = adapter.parse(expanded)
        draft.title = title if title && !title.to_s.strip.empty?
        document = @builder.build(
          draft,
          kind: "book",
          source_hash: source_hash,
          ttl_seconds: nil
        )
        mark_ingested(document, source_hash, path: expanded)
        stored = @store.add(document)
        Result.new(document: stored, cached: stored.id != document.id)
      rescue UnsupportedFormatError => e
        raise UnsupportedFormatError.new(
          e.message,
          details: e.details.merge(stage: "parse", reason: "parse_error", parser_message: e.message)
        )
      rescue OcrRequiredError => e
        raise OcrRequiredError.new(
          e.message,
          details: e.details.merge(stage: "parse", reason: "ocr_required", parser_message: e.message)
        )
      end

      def ingest_text(text = nil, title: nil, format: nil, language: nil, ttl_seconds: nil, source_path: nil, source_url: nil)
        sources = [text, source_path, source_url].compact.reject { |value| value.to_s.empty? }
        if sources.length > 1
          raise ValidationError.new(
            "Provide text, source_path, or source_url, not more than one",
            details: { reason: "multiple_sources" }
          )
        end
        if sources.empty?
          raise ValidationError.new(
            "Provide text, source_path, or source_url",
            details: { reason: "missing_source" }
          )
        end

        content, title = load_text_source(text, title: title, source_path: source_path, source_url: source_url)
        validate_text_content!(content)

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

        format = (format || inferred_format(source_path || source_url) || "plain").to_s
        unless %w[plain markdown].include?(format)
          raise ValidationError.new(
            "Unsupported text format",
            details: { format: format, supported: %w[plain markdown] }
          )
        end

        source_hash = Digest::SHA256.hexdigest("#{format}\0#{content}")
        existing = @store.find_by_source_hash(source_hash)
        if existing && !existing.expired?
          @cache_hits += 1
          return Result.new(document: existing, cached: true)
        end

        @cache_misses += 1
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
        mark_ingested(document, source_hash, path: source_path || source_url)
        stored = @store.add(document)
        Result.new(document: stored, cached: stored.id != document.id)
      end

      def cache_stats
        { hits: @cache_hits, misses: @cache_misses }
      end

      def remove(document_id)
        document = @store.find_document(document_id)
        raise NotFoundError.new("Document not found", details: { document_id: document_id }) unless document

        @store.remove(document_id)
        document
      end

      private

      def remove_documents_for_path(path)
        @store.documents.each do |document|
          stored_path = document.metadata.dig(:ingest, :path)
          next unless stored_path

          @store.remove(document.id) if resolve_path(stored_path) == path
        end
      end

      def mark_ingested(document, source_hash, path:)
        document.metadata[:ingest] = {
          cached: false,
          source_hash: source_hash,
          path: path
        }
      end

      def load_text_source(text, title:, source_path:, source_url:)
        if source_path
          resolved = resolve_path(source_path)
          unless File.file?(resolved)
            raise NotFoundError.new(
              "Text file not found",
              details: {
                path: resolved,
                requested_path: source_path.to_s,
                reason: "file_not_found",
                hint: DOCKER_PATH_HINT
              }
            )
          end
          unless text_source_path?(resolved)
            raise ValidationError.new(
              "source_path must be a text or Markdown file; use ingest_book for books",
              details: { path: resolved, reason: "non_text_source" }
            )
          end

          [Util::Text.read_text_file(resolved), title || File.basename(resolved, ".*")]
        elsif source_url
          from_url_title = url_title(source_url)
          [fetch_url(source_url), title || from_url_title]
        else
          [text.to_s, title]
        end
      end

      def text_source_path?(path)
        extension = File.extname(path).downcase
        extension.empty? || %w[.txt .text .md .markdown].include?(extension)
      end

      def inferred_format(source)
        return nil if source.nil?

        path = source.to_s
        path = URI.parse(path).path.to_s if path.match?(%r{\Ahttps?://}i)
        return "markdown" if path.downcase.end_with?(".md", ".markdown")
        return "plain" if path.downcase.end_with?(".txt", ".text")

        nil
      rescue URI::InvalidURIError
        nil
      end

      def url_title(url)
        path = URI.parse(url.to_s).path.to_s
        title = File.basename(path, ".*")
        title.empty? || title == "." ? nil : title
      rescue URI::InvalidURIError
        nil
      end

      def validate_text_content!(content)
        stripped = content.to_s.strip
        raise ValidationError.new("Text must not be empty") if stripped.empty?

        if PLACEHOLDER_PATTERNS.any? { |pattern| stripped.match?(pattern) }
          raise ValidationError.new(
            "Text looks like a placeholder or service value",
            details: { reason: "placeholder" }
          )
        end
        unless stripped.match?(/[\p{L}\p{N}]/u)
          raise ValidationError.new(
            "Text must contain letters or numbers",
            details: { reason: "no_content" }
          )
        end
      end

      def fetch_url(url, redirects: MAX_REDIRECTS)
        uri = URI.parse(url.to_s)
        unless %w[http https].include?(uri.scheme.to_s.downcase) && uri.host
          raise ValidationError.new(
            "Unsupported URL",
            details: { url: url.to_s, reason: "unsupported_url" }
          )
        end

        result = nil
        Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: uri.scheme.to_s.downcase == "https",
          open_timeout: 5,
          read_timeout: 10
        ) do |http|
          request = Net::HTTP::Get.new(uri.request_uri, "User-Agent" => "bookworm-mcp")
          http.request(request) do |response|
            result = case response
                     when Net::HTTPSuccess
                       content_type = response["content-type"].to_s.downcase
                       if !content_type.empty? && !content_type.match?(/text|markdown|json|xml/)
                         raise ValidationError.new(
                           "URL does not look like a text resource",
                           details: { url: url.to_s, reason: "non_text_url", content_type: content_type }
                         )
                       end
                       [:ok, read_limited_body(response, url)]
                     when Net::HTTPRedirection
                       [:redirect, response["location"]]
                     else
                       [:error, response.code.to_i]
                     end
          end
        end

        kind, value = result
        case kind
        when :ok
          value
        when :redirect
          if redirects <= 0 || value.to_s.empty?
            raise ValidationError.new("Too many URL redirects", details: { url: url.to_s, reason: "too_many_redirects" })
          end

          fetch_url(URI.join(url.to_s, value).to_s, redirects: redirects - 1)
        else
          raise ValidationError.new(
            "Cannot fetch URL",
            details: { url: url.to_s, status: value, reason: "fetch_failed" }
          )
        end
      rescue URI::InvalidURIError
        raise ValidationError.new("Invalid URL", details: { url: url.to_s, reason: "invalid_url" })
      rescue SocketError, Timeout::Error, OpenSSL::SSL::SSLError, Errno::ECONNREFUSED => e
        raise ValidationError.new(
          "Cannot fetch URL",
          details: { url: url.to_s, reason: "fetch_failed", error: e.message }
        )
      end

      def read_limited_body(response, url)
        body = +""
        response.read_body do |chunk|
          body << chunk
          if body.bytesize > @config.max_inline_bytes
            raise TextTooLargeError.new(
              "Fetched text is too large",
              details: { url: url.to_s, max_bytes: @config.max_inline_bytes, reason: "remote_too_large" }
            )
          end
        end
        Util::Text.decode_bytes(body)
      end

      def resolve_path(path)
        expanded = File.expand_path(normalize_unicode(path.to_s))
        return expanded if File.exist?(expanded)

        parent = File.dirname(expanded)
        return expanded if parent == expanded

        resolved_parent = resolve_path(parent)
        base = File.basename(expanded)
        candidate = File.join(resolved_parent, base)
        return candidate if File.exist?(candidate)

        if Dir.exist?(resolved_parent)
          normalized_base = normalize_unicode(base)
          match = Dir.children(resolved_parent).find do |name|
            normalize_unicode(name) == normalized_base
          end
          return File.join(resolved_parent, match) if match
        end

        candidate
      rescue ArgumentError
        File.expand_path(path.to_s)
      end

      def normalize_unicode(value)
        value.unicode_normalize(:nfc)
      end
    end
  end
end
