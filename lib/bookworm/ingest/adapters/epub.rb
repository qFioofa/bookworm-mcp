# frozen_string_literal: true

require "zip"
require "rexml/document"

module Bookworm
  module Ingest
    module Adapters
      class Epub
        BLOCK_TAGS = {
          "h1" => [:heading, 2], "h2" => [:heading, 3], "h3" => [:heading, 4],
          "h4" => [:heading, 5], "h5" => [:heading, 6], "h6" => [:heading, 6],
          "p" => [:paragraph, nil], "li" => [:list_item, nil],
          "blockquote" => [:quote, nil], "pre" => [:code, nil],
          "td" => [:table, nil], "th" => [:table, nil],
          "figcaption" => [:paragraph, nil]
        }.freeze
        CONTAINER_TAGS = %w[body div section article main header footer aside].freeze
        TOC_MIN_LINKS = 5
        TOC_LINK_TEXT_RATIO = 0.6
        TOC_LINK_PATTERN = /<a\b[^>]*>(.*?)<\/a>/mi

        def parse(path)
          Zip::File.open(path) do |zip|
            container = read_xml(zip, "META-INF/container.xml")
            opf_path = find_rootfile(container)
            raise UnsupportedFormatError.new("EPUB has no package document") unless opf_path

            opf = read_xml(zip, opf_path)
            metadata = parse_metadata(opf)
            manifest = parse_manifest(opf)
            spine = parse_spine(opf)
            base_dir = File.dirname(opf_path)

            blocks = []
            spine.each_with_index do |idref, index|
              item = manifest[idref]
              next unless item
              next unless item[:media_type].to_s.include?("html")
              next if nav_item?(item)

              entry_path = resolve_path(base_dir, item[:href])
              content = zip.read(entry_path) rescue nil
              next unless content
              next if toc_document?(content)

              html_blocks = extract_html_blocks(content)
              next if html_blocks.empty?

              title = html_blocks.find(&:heading?)&.text || "Chapter #{index + 1}"
              blocks << Block.new(type: :chapter, text: title, level: 1, title: title)
              html_blocks.shift if html_blocks.first&.heading? && same_text?(html_blocks.first.text, title)
              blocks.concat(html_blocks)
            end

            if blocks.empty?
              raise UnsupportedFormatError.new("EPUB contains no readable text", details: { path: path })
            end

            title = metadata[:title].to_s.strip
            title = File.basename(path, ".*") if title.empty?

            Draft.new(
              title: title,
              authors: metadata[:authors],
              language: metadata[:language],
              format: "epub",
              blocks: blocks,
              metadata: metadata.merge(path: path)
            )
          end
        end

        private

        def read_xml(zip, path)
          content = zip.read(path)
          REXML::Document.new(content)
        rescue StandardError => e
          raise UnsupportedFormatError.new("Cannot read EPUB entry #{path}: #{e.message}")
        end

        def nav_item?(item)
          item[:properties].to_s.split(/\s+/).include?("nav")
        end

        def toc_document?(content)
          html = content.to_s
          links = html.scan(TOC_LINK_PATTERN)
          return false if links.length < TOC_MIN_LINKS

          total_text = plain_text(html)
          return false if total_text.empty?

          link_text = links.map { |capture| plain_text(capture.first) }.join(" ")
          link_text.length >= total_text.length * TOC_LINK_TEXT_RATIO
        end

        def plain_text(html)
          text = html.to_s
                     .gsub(/<script.*?<\/script>/mi, " ")
                     .gsub(/<style.*?<\/style>/mi, " ")
                     .gsub(/<[^>]+>/, " ")
          Util::Text.decode_entities(text).gsub(/\s+/, " ").strip
        end

        def find_rootfile(document)
          rootfile = find_first(document.root, "rootfile")
          rootfile&.attributes&.[]("full-path")
        end

        def parse_metadata(opf)
          metadata = find_first(opf.root, "metadata")
          {
            title: text_of(find_first(metadata, "title")),
            authors: find_all(metadata, "creator").map { |element| text_of(element) }.compact.reject(&:empty?),
            language: text_of(find_first(metadata, "language")),
            identifiers: find_all(metadata, "identifier").map { |element| text_of(element) }.compact
          }
        end

        def parse_manifest(opf)
          manifest = find_first(opf.root, "manifest")
          find_all(manifest, "item").each_with_object({}) do |item, result|
            id = item.attributes["id"]
            next unless id

            result[id] = {
              href: item.attributes["href"],
              media_type: item.attributes["media-type"],
              properties: item.attributes["properties"]
            }
          end
        end

        def parse_spine(opf)
          spine = find_first(opf.root, "spine")
          find_all(spine, "itemref").map { |item| item.attributes["idref"] }.compact
        end

        def extract_html_blocks(content)
          document = REXML::Document.new(content)
          blocks = []
          walk_html(document.root, blocks) if document.root
          blocks = fallback_blocks(content) if blocks.empty?
          blocks
        rescue StandardError
          fallback_blocks(content)
        end

        def walk_html(element, blocks)
          element.each_child do |child|
            next unless child.is_a?(REXML::Element)

            name = child.name.downcase
            next if %w[script style head title nav].include?(name)

            if BLOCK_TAGS.key?(name)
              text = clean_text(text_of(child))
              unless text.empty?
                type, level = BLOCK_TAGS[name]
                blocks << Block.new(type: type, text: text, level: level)
              end
            elsif CONTAINER_TAGS.include?(name)
              walk_html(child, blocks)
            else
              walk_html(child, blocks)
            end
          end
        end

        def fallback_blocks(content)
          text = Util::Text.decode_entities(content.gsub(/<script.*?<\/script>/m, " ").gsub(/<style.*?<\/style>/m, " "))
          text = text.gsub(/<\/(?:p|div|h[1-6]|li|blockquote|pre)>/i, "\n\n")
          text = text.gsub(/<br\s*\/?>/i, "\n").gsub(/<[^>]+>/, " ")
          Util::Text.collapse_whitespace(text)
                   .split(/\n\s*\n/)
                   .map(&:strip)
                   .reject(&:empty?)
                   .map { |paragraph| Block.new(type: :paragraph, text: paragraph) }
        end

        def text_of(element)
          return "" unless element

          output = +""
          element.each_child do |child|
            if child.is_a?(REXML::Text)
              output << child.value
            elsif child.is_a?(REXML::Element)
              output << " " if %w[br p div li td th].include?(child.name.downcase)
              output << text_of(child)
              output << " " if %w[br p div li td th].include?(child.name.downcase)
            end
          end
          Util::Text.decode_entities(output)
        end

        def clean_text(text)
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

        def find_all(element, name)
          return [] unless element

          result = []
          element.each_element do |child|
            result << child if child.name.downcase == name
            result.concat(find_all(child, name))
          end
          result
        end

        def resolve_path(base_dir, href)
          path = href.to_s.split("#").first.to_s
          return path.sub(%r{\A/}, "") if path.start_with?("/")

          parts = base_dir.to_s.split("/") + path.split("/")
          resolved = []
          parts.each do |part|
            next if part.empty? || part == "."

            if part == ".."
              resolved.pop
            else
              resolved << part
            end
          end
          resolved.join("/")
        end

        def same_text?(left, right)
          Util::Text.normalize_for_match(left) == Util::Text.normalize_for_match(right)
        end
      end
    end
  end
end
