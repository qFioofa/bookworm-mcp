# frozen_string_literal: true

require "open3"

module Bookworm
  module Ingest
    module Adapters
      class Djvu
        def parse(path)
          output, error, status = Open3.capture3("djvutxt", path)
          unless status.success?
            raise UnsupportedFormatError.new(
              "Cannot extract DjVu text: #{error.strip}",
              details: { path: path, hint: "install djvulibre-bin" }
            )
          end

          pages = output.split("\f")
          blocks = []
          pages.each_with_index do |page_text, index|
            text = Util::Text.normalize_newlines(page_text)
            text.split(/\n\s*\n/).map(&:strip).reject(&:empty?).each do |paragraph|
              blocks << Block.new(type: :paragraph, text: paragraph, page: index + 1)
            end
          end

          if blocks.empty?
            raise OcrRequiredError.new(
              "DjVu has no text layer; OCR is required before ingestion",
              details: { path: path }
            )
          end

          Draft.new(
            title: File.basename(path, ".*"),
            authors: [],
            language: Util::Text.detect_language(blocks.map(&:text).join(" ")),
            format: "djvu",
            blocks: blocks,
            metadata: { path: path, pages: pages.length }
          )
        rescue Errno::ENOENT
          raise DependencyMissingError.new(
            "djvutxt is not installed",
            details: { path: path, hint: "install djvulibre-bin" }
          )
        end
      end
    end
  end
end
