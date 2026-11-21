# frozen_string_literal: true

module Bookworm
  module Ingest
    module Adapters
      module Registry
        module_function

        def for_path(path)
          extension = File.extname(path).downcase
          return Fb2.new if path.to_s.downcase.end_with?(".fb2.zip")

          case extension
          when ".epub" then Epub.new
          when ".pdf" then Pdf.new
          when ".fb2" then Fb2.new
          when ".djvu" then Djvu.new
          when ".md", ".markdown" then TextFile.new(format: "markdown")
          when ".txt", ".text", "" then TextFile.new(format: "plain")
          else
            raise UnsupportedFormatError.new(
              "Unsupported book format: #{extension.empty? ? "unknown" : extension}",
              details: { path: path, supported: %w[.epub .pdf .fb2 .fb2.zip .djvu .md .txt] }
            )
          end
        end

        class TextFile
          def initialize(format:)
            @format = format
          end

          def parse(path)
            text = Util::Text.read_text_file(path)
            Text.parse(
              text,
              title: File.basename(path, ".*"),
              format: @format,
              language: Util::Text.detect_language(text)
            ).tap do |draft|
              draft.metadata = draft.metadata.merge(path: path)
            end
          end
        end
      end
    end
  end
end
