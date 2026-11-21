# frozen_string_literal: true

module Bookworm
  module Ingest
    module Adapters
      class Text
        def self.parse(text, title: nil, format: "plain", language: nil)
          normalized = Util::Text.normalize_newlines(text)
          blocks = format == "markdown" ? parse_markdown(normalized) : parse_plain(normalized)
          first_heading = blocks.find(&:heading?)&.text
          Draft.new(
            title: title || first_heading || "Untitled text",
            authors: [],
            language: language || Util::Text.detect_language(normalized),
            format: format,
            blocks: blocks,
            metadata: { characters: normalized.length }
          )
        end

        def self.parse_markdown(text)
          blocks = []
          paragraph = []
          table = []
          code = []
          in_code = false
          fence = nil

          flush_paragraph = lambda do
            unless paragraph.empty?
              blocks << Block.new(type: :paragraph, text: clean(paragraph.join("\n")))
              paragraph.clear
            end
          end

          flush_table = lambda do
            unless table.empty?
              blocks << Block.new(type: :table, text: table.join("\n"))
              table.clear
            end
          end

          text.lines(chomp: true).each do |line|
            if in_code
              if line.strip.start_with?(fence)
                blocks << Block.new(type: :code, text: code.join("\n"))
                code.clear
                in_code = false
                fence = nil
              else
                code << line
              end
              next
            end

            if line.match?(/\A\s*(```|~~~)/)
              flush_paragraph.call
              flush_table.call
              fence = line.strip[0, 3]
              in_code = true
              next
            end

            if line.strip.empty?
              flush_paragraph.call
              flush_table.call
              next
            end

            if (heading = line.match(/\A(\#{1,6})\s+(.+?)\s*#*\z/))
              flush_paragraph.call
              flush_table.call
              blocks << Block.new(type: :heading, text: clean(heading[2]), level: heading[1].length)
              next
            end

            if line.strip.match?(/\A([-*_])\s*\1\s*\1[\s\-*_]*\z/)
              flush_paragraph.call
              flush_table.call
              next
            end

            if line.strip.start_with?("|")
              flush_paragraph.call
              table << line.strip
              next
            end

            flush_table.call

            if (item = line.match(/\A\s*(?:[-*+]|\d+[.)])\s+(.+)\z/))
              flush_paragraph.call
              next if toc_link_item?(item[1])

              blocks << Block.new(type: :list_item, text: clean(item[1]))
              next
            end

            if (quote = line.match(/\A>\s?(.*)\z/))
              flush_paragraph.call
              blocks << Block.new(type: :quote, text: clean(quote[1]))
              next
            end

            paragraph << line
          end

          if in_code && !code.empty?
            blocks << Block.new(type: :code, text: code.join("\n"))
          end
          flush_paragraph.call
          flush_table.call
          blocks
        end

        def self.parse_plain(text)
          blocks = []
          paragraph = []

          flush = lambda do
            unless paragraph.empty?
              blocks << Block.new(type: :paragraph, text: paragraph.join(" ").strip)
              paragraph.clear
            end
          end

          text.lines(chomp: true).each do |line|
            stripped = line.strip
            if stripped.empty?
              flush.call
              next
            end

            if stripped.length <= 100 && LanguageData.heading_patterns.any? { |pattern| stripped.match?(pattern) }
              flush.call
              blocks << Block.new(type: :heading, text: stripped, level: 1)
              next
            end

            paragraph << stripped
          end

          flush.call
          blocks
        end

        def self.toc_link_item?(text)
          value = text.to_s.strip
          return false if value.empty?
          return false unless value.match?(/\[[^\]]+\]\(#[^)]+\)/)

          remainder = value.gsub(/\[[^\]]+\]\(#[^)]*\)/, "").gsub(/[\s·|,;:–—-]+/, "")
          remainder.empty?
        end

        def self.clean(text)
          Util::Text.strip_inline_markdown(text.to_s).gsub(/<[^>]+>/, " ").strip
        end
      end
    end
  end
end
