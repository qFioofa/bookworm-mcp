# frozen_string_literal: true

require "rexml/document"
require "zip"

module Bookworm
  module Ingest
    module Adapters
      class Fb2
        PARAGRAPH_TAGS = %w[p v text].freeze
        BLOCK_TAGS = %w[epigraph cite poem stanza annotation].freeze
        SKIP_TAGS = %w[binary coverpage image].freeze
        NOTE_BODY_NAMES = %w[notes comments footnotes].freeze

        def parse(path)
          xml = read_xml(path)
          document = REXML::Document.new(xml)
          root = document.root
          raise UnsupportedFormatError.new("FB2 has no root element", details: { path: path }) unless root

          metadata = parse_metadata(root)
          bodies = root.elements.to_a.select { |element| element.name.downcase == "body" }
          note_bodies, text_bodies = bodies.partition { |body| note_body?(body) }

          footnotes = note_bodies.flat_map { |body| parse_notes(body) }
          blocks = []
          text_bodies.each { |body| walk(body, blocks, depth: 0) }

          blocks = fallback_blocks(text_bodies, root) if blocks.empty?
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
            metadata: metadata.merge(path: path, footnotes: footnotes.length),
            footnotes: footnotes
          )
        rescue REXML::ParseException => e
          raise UnsupportedFormatError.new("Cannot read FB2 XML: #{e.message}", details: { path: path })
        rescue Zip::Error => e
          raise UnsupportedFormatError.new("Cannot read FB2 archive: #{e.message}", details: { path: path })
        end

        private

        def read_xml(path)
          raw = zip?(path) ? read_zip_entry(path) : File.binread(path)
          normalize_declaration(decode_xml(raw))
        end

        def normalize_declaration(xml)
          xml.sub(/<\?xml[^>]*\?>/i) do |declaration|
            declaration.sub(/encoding=(["'])[^"']+\1/i, 'encoding="UTF-8"')
          end
        end

        def zip?(path)
          File.binread(path, 4) == "PK\x03\x04".b
        end

        def read_zip_entry(path)
          Zip::File.open(path) do |zip|
            entry = zip.entries.find { |item| item.name.downcase.end_with?(".fb2") }
            entry ||= zip.entries.find { |item| !item.directory? && zip.entries.length == 1 }
            raise Zip::Error, "archive contains no FB2 entry" unless entry

            zip.read(entry)
          end
        end

        def decode_xml(raw)
          data = raw.dup
          return Util::Text.decode_bytes(data) if bom?(data)

          utf8 = data.force_encoding(Encoding::UTF_8)
          return Util::Text.normalize_newlines(utf8) if utf8.valid_encoding?

          header = data.byteslice(0, 300).to_s.force_encoding(Encoding::ASCII_8BIT)
          declaration = header.match(/encoding=["']([^"']+)["']/i)&.[](1)
          if declaration && !%w[utf-8 utf8].include?(declaration.downcase)
            begin
              encoding = Encoding.find(declaration)
              return Util::Text.normalize_newlines(data.force_encoding(encoding).encode(Encoding::UTF_8))
            rescue ArgumentError, EncodingError
              # Fall back to BOM/mojibake detection below.
            end
          end

          Util::Text.decode_bytes(data)
        end

        def bom?(data)
          data.start_with?("\xEF\xBB\xBF".b) ||
            data.start_with?("\xFF\xFE".b) ||
            data.start_with?("\xFE\xFF".b)
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
            language: clean(text_of(find_first(title_info, "lang"))),
            annotation: clean(text_of(find_first(title_info, "annotation")))
          }
        end

        def note_body?(body)
          NOTE_BODY_NAMES.include?(body.attributes["name"].to_s.downcase)
        end

        def parse_notes(body)
          body.elements.to_a.each_with_index.filter_map do |section, index|
            next unless section.name.downcase == "section"

            anchor = section.attributes["id"].to_s.strip
            anchor = "note_#{index + 1}" if anchor.empty?
            title = find_direct(section, "title")
            label = clean(text_of(title))
            label = anchor if label.empty?
            text = note_text(section)
            next if text.empty?

            Domain::Footnote.new(id: anchor, label: label, text: text)
          end
        end

        def note_text(section)
          pieces = []
          section.each_child do |child|
            next unless child.is_a?(REXML::Element)

            name = child.name.downcase
            next if name == "title" || SKIP_TAGS.include?(name)

            collect_note_pieces(child, pieces)
          end
          pieces.map { |piece| clean(piece) }.reject(&:empty?).join("\n\n")
        end

        def collect_note_pieces(element, pieces)
          name = element.name.downcase
          if PARAGRAPH_TAGS.include?(name) || %w[subtitle].include?(name)
            text, = text_with_notes(element)
            pieces << text unless text.empty?
            return
          end

          return if SKIP_TAGS.include?(name)

          element.each_child do |child|
            next unless child.is_a?(REXML::Element)

            collect_note_pieces(child, pieces)
          end
        end

        def walk(element, blocks, depth:)
          element.each_child do |child|
            next unless child.is_a?(REXML::Element)

            name = child.name.downcase
            next if SKIP_TAGS.include?(name)

            case name
            when "section"
              title, footnote_ids = section_title(child)
              unless title.empty?
                blocks << Block.new(
                  type: depth.zero? ? :chapter : :heading,
                  text: title,
                  level: depth.zero? ? 1 : [depth + 1, 6].min,
                  footnote_ids: footnote_ids
                )
              end
              walk(child, blocks, depth: depth + 1)
            when "title"
              next
            when "subtitle"
              text, footnote_ids = text_with_notes(child, strip_notes: true)
              text = clean_title(text)
              unless text.empty?
                blocks << Block.new(
                  type: :heading,
                  text: text,
                  level: [depth + 1, 6].min,
                  footnote_ids: footnote_ids
                )
              end
            when *PARAGRAPH_TAGS
              text, footnote_ids = text_with_notes(child)
              unless text.empty?
                blocks << Block.new(type: :paragraph, text: text, footnote_ids: footnote_ids)
              end
            when "table"
              table_blocks(child, blocks)
            when *BLOCK_TAGS
              walk(child, blocks, depth: depth)
            else
              walk(child, blocks, depth: depth) if child.has_elements?
            end
          end
        end

        def table_blocks(table, blocks)
          rows = table.elements.to_a.select { |element| element.name.downcase == "tr" }
          if rows.empty?
            text, footnote_ids = text_with_notes(table)
            blocks << Block.new(type: :table, text: text, footnote_ids: footnote_ids) unless text.empty?
            return
          end

          rows.each do |row|
            cells = row.elements.to_a.select { |element| %w[td th].include?(element.name.downcase) }
            footnote_ids = []
            text = cells.map do |cell|
              value, refs = text_with_notes(cell)
              footnote_ids.concat(refs)
              value
            end.reject(&:empty?).join(" | ")
            next if text.empty?

            blocks << Block.new(type: :table, text: text, footnote_ids: footnote_ids.uniq)
          end
        end

        def section_title(section)
          title = find_direct(section, "title")
          return ["", []] unless title

          text, footnote_ids = text_with_notes(title, strip_notes: true)
          [clean_title(text), footnote_ids]
        end

        def text_with_notes(element, strip_notes: false)
          footnote_ids = []
          text = extract_text(element, footnote_ids, strip_notes: strip_notes)
          [clean(text), footnote_ids.uniq]
        end

        def extract_text(element, footnote_ids, strip_notes: false)
          return "" unless element

          output = +""
          element.each_child do |child|
            if child.is_a?(REXML::Text)
              output << child.value
            elsif child.is_a?(REXML::Element)
              name = child.name.downcase
              if name == "a" && child.attributes["type"].to_s.downcase == "note"
                anchor = note_anchor(child)
                footnote_ids << anchor if anchor
                output << nested_text(child, footnote_ids, strip_notes: strip_notes) unless strip_notes
              elsif name == "br"
                output << "\n"
              elsif SKIP_TAGS.include?(name)
                next
              elsif PARAGRAPH_TAGS.include?(name) || %w[subtitle stanza].include?(name)
                output << " " << nested_text(child, footnote_ids, strip_notes: strip_notes) << " "
              else
                output << nested_text(child, footnote_ids, strip_notes: strip_notes)
              end
            end
          end
          Util::Text.decode_entities(output)
        end

        def nested_text(element, footnote_ids, strip_notes:)
          extract_text(element, footnote_ids, strip_notes: strip_notes)
        end

        def note_anchor(element)
          href = element.attributes["l:href"] || element.attributes["href"]
          value = href.to_s.strip
          return nil if value.empty?

          value.delete_prefix("#")
        end

        def text_of(element)
          return "" unless element

          extract_text(element, [], strip_notes: true)
        end

        def clean(text)
          Util::Text.collapse_whitespace(text)
        end

        def clean_title(text)
          text.to_s.gsub(/\s+/, " ").strip
        end

        def fallback_blocks(bodies, root)
          text = bodies.map { |body| extract_text(body, [], strip_notes: true) }.join("\n\n")
          text = extract_text(root, [], strip_notes: true) if text.strip.empty?
          clean(text).split(/\n\s*\n/).map(&:strip).reject(&:empty?).map do |paragraph|
            Block.new(type: :paragraph, text: paragraph)
          end
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
