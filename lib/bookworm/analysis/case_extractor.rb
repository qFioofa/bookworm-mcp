# frozen_string_literal: true

require "digest"

module Bookworm
  module Analysis
    class CaseExtractor
      MARKERS = LanguageData.case_markers

      MAX_CASES = 1000

      def initialize(document, mentions)
        @document = document
        @mentions_by_passage = mentions.group_by(&:passage_id)
      end

      def call
        cases = @document.passages.filter_map do |passage|
          markers = markers_for(passage)
          heading = heading_marker?(passage)
          next if markers.empty? && !heading

          build_case(passage, markers, heading)
        end

        cases.sort_by { |item| item.citation[:start_char] }.first(MAX_CASES)
      end

      private

      def markers_for(passage)
        MARKERS.filter_map do |pattern|
          match = passage.text.match(pattern)
          match && match[0].downcase.strip
        end.uniq
      end

      def heading_marker?(passage)
        passage.chapter_path.any? do |title|
          LanguageData.case_heading_patterns.any? { |pattern| title.match?(pattern) }
        end
      end

      def build_case(passage, markers, heading)
        kind = kind_for(markers, passage)
        Case.new(
          id: "case_#{Digest::SHA1.hexdigest("#{@document.id}:#{passage.id}")[0, 12]}",
          document_id: @document.id,
          passage_id: passage.id,
          title: title_for(passage),
          kind: kind,
          markers: markers,
          text: passage.text,
          citation: Domain::Citation.build(document: @document, passage: passage),
          linked_entity_ids: (@mentions_by_passage[passage.id] || []).map(&:entity_id).uniq,
          confidence: confidence_for(markers, heading),
          method: "marker"
        )
      end

      def kind_for(markers, passage)
        text = "#{markers.join(" ")} #{passage.text}"
        LanguageData.case_kind_patterns.each do |kind, patterns|
          return kind if patterns.any? { |pattern| text.match?(pattern) }
        end

        "example"
      end

      def title_for(passage)
        chapter = passage.chapter_path.last
        if chapter && !chapter.empty?
          Bookworm::I18n.t("cases.title_with_chapter", chapter: chapter)
        else
          Bookworm::I18n.t("cases.default_title")
        end
      end

      def confidence_for(markers, heading)
        return 0.9 if markers.length > 1
        return 0.8 if heading

        0.7
      end
    end
  end
end
