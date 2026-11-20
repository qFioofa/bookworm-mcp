# frozen_string_literal: true

require "rexml/document"

module Bookworm
  module Ingest
    module Adapters
      class Fb2
        TEXT_TAGS = %w[p subtitle v text].freeze
        SKIP_TAGS = %w[binary coverpage image].freeze

        def parse(path)
          document = REXML::Document.new(File.binread(path))
          root = document.root
          raise UnsupportedFormatError.new("FB2 has no root element", details: { path: path }) unless root

          metadata = parse_metadata(root)
          blocks = []
          bodies = find_all(root, "body")
          bodies.each do |body|
            next if body.attributes["name"].to_s == "notes"

            walk(body, blocks, depth: 0)
          end

          blocks = fallback_blocks(root) if blocks.empty?
          if blocks.empty?
            raise UnsupportedFormatError.new("FB2 contains no readable text", details: { path: path })
          end

          title = metadata[:title].to_s.strip
          title = File.basename(path, ".*") if title.empty?

          Draft.new(
            title: title,
            authors: metadata[:authors],
            language: metadata[:language],
            format: "fb2",
            blocks: blocks,
            metadata: metadata.merge(path: path)
          )
        rescue REXML::ParseException => e
          raise UnsupportedFormatError.new("Cannot read FB2 XML: #{e.message}", details: { path: path })
        end

        private

        def walk(element, blocks, depth:)
          element.each_child do |child|
            next unless child.is_a?(REXML::Element)

            name = child.name.downcase
            next if SKIP_TAGS.include?(name)

            case name
            when "section"
              title = section_title(child)
              if title && !title.empty?
                blocks << Block.new(
                  type: depth.zero? ? :chapter : :heading,
                  text: title,
                  level: depth.zero? ? 1 : [depth + 1, 6].min
                )
              end
              walk(child, blocks, depth: depth + 1)
            when "title"
              next
            when "subtitle"
              text = clean(text_of(child))
              blocks << Block.new(type: :heading, text: text, level: [depth + 1, 6].min) unless text.empty?
            when *TEXT_TAGS
              text = clean(text_of(child))
              blocks << Block.new(type: :paragraph, text: text) unless text.empty?
            when "epigraph", "cite", "poem", "stanza", "annotation", "notes"
              walk(child, blocks, depth: depth)
            else
              walk(child, blocks, depth: depth) if child.has_elements?
            end
          end
        end

        def section_title(section)
          title = find_direct(section, "title")
          return nil unless title

          clean(text_of(title))
        end

        def parse_metadata(root)
          description = find_first(root, "description")
          title_info = find_first(description, "title-info")
          authors = find_all(title_info, "author").map do |author|
            [find_first(author, "first-name"), find_first(author, "middle-name"), find_first(author, "last-name")]
              .compact
              .map { |element| clean(text_of(element)) }
              .reject(&:empty?)
              .join(" ")
          end.reject(&:empty?)

          {
            title: clean(text_of(find_first(title_info, "book-title"))),
            authors: authors,
            language: clean(text_of(find_first(title_info, "lang")))
          }
        end

        def fallback_blocks(root)
          text = clean(text_of(root))
          text.split(/\n\s*\n/).map(&:strip).reject(&:empty?).map do |paragraph|
            Block.new(type: :paragraph, text: paragraph)
          end
        end

        def text_of(element)
          return "" unless element

          output = +""
          element.each_child do |child|
            if child.is_a?(REXML::Text)
              output << child.value
            elsif child.is_a?(REXML::Element)
              output << " " if %w[p v subtitle text stanza].include?(child.name.downcase)
              output << text_of(child)
              output << " " if %w[p v subtitle text stanza].include?(child.name.downcase)
            end
          end
          Util::Text.decode_entities(output)
        end

        def clean(text)
          Util::Text.collapse_whitespace(text)
        end

        def find_first(element, name)
          return nil unless element

          element.each_element do |child|
            return child if child.name.downcase == name

            found = find_first(child, name)
            return found if found
          end
          nil
        end

        def find_direct(element, name)
          element.each_element do |child|
            return child if child.name.downcase == name
          end
          nil
        end

        def find_all(element, name)
          return [] unless element

          result = []
          element.each_element do |child|
            result << child if child.name.downcase == name
            result.concat(find_all(child, name))
          end
          result
        end
      end
    end
  end
end
