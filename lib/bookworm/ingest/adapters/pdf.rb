# frozen_string_literal: true

require "pdf-reader"

module Bookworm
  module Ingest
    module Adapters
      class Pdf
        NUMBERED_HEADING = /\A\d+(?:\.\d+)*[.)]?\s+\S/

        def parse(path)
          reader = PDF::Reader.new(path)
          blocks = []
          empty_pages = 0

          reader.pages.each do |page|
            page_number = page.number
            text = page.text.to_s
            if text.strip.empty?
              empty_pages += 1
              next
            end
            blocks.concat(parse_page(text, page_number))
          end

          if blocks.empty?
            raise OcrRequiredError.new(
              "PDF has no text layer; OCR is required before ingestion",
              details: { path: path, pages: reader.page_count }
            )
          end

          info = reader.info || {}
          title = (info[:Title] || info["Title"]).to_s.strip
          title = File.basename(path, ".*") if title.empty?
          author = (info[:Author] || info["Author"]).to_s.strip

          Draft.new(
            title: title,
            authors: author.empty? ? [] : [author],
            language: Util::Text.detect_language(blocks.map(&:text).join(" ")),
            format: "pdf",
            blocks: blocks,
            metadata: {
              path: path,
              pages: reader.page_count,
              empty_pages: empty_pages,
              pdf_info: info.transform_keys(&:to_s)
            }
          )
        rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError => e
          raise UnsupportedFormatError.new("Cannot read PDF: #{e.message}", details: { path: path })
        end

        private

        def parse_page(text, page_number)
          blocks = []
          paragraph = []
          flush = lambda do
            unless paragraph.empty?
              blocks << Block.new(type: :paragraph, text: paragraph.join(" ").strip, page: page_number)
              paragraph.clear
            end
          end

          text.each_line do |line|
            stripped = line.strip
            if stripped.empty?
              flush.call
              next
            end

            if heading?(stripped)
              flush.call
              blocks << Block.new(type: :heading, text: stripped, level: 2, page: page_number)
              next
            end

            paragraph << stripped
          end

          flush.call
          blocks
        end

        def heading?(line)
          return false if line.length > 100
          return true if LanguageData.heading_patterns.any? { |pattern| line.match?(pattern) }
          return true if line.match?(NUMBERED_HEADING) && line.length < 80

          letters = line.gsub(/[^\p{L}]/u, "")
          letters.length >= 3 && letters == letters.upcase && line.length < 60
        end
      end
    end
  end
end
