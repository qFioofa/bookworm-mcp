# frozen_string_literal: true

require "digest"
require "set"

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
        groups = build_groups
        cases = groups.filter_map { |group| build_case(group) }
        cases.sort_by { |item| item.start_char.to_i }.first(MAX_CASES)
      end

      private

      def build_groups
        passages = @document.passages.sort_by(&:ordinal)
        heading_node_ids = passages.select { |passage| heading_marker?(passage) }.map(&:node_id).uniq
        groups = []
        used = Set.new

        heading_node_ids.each do |node_id|
          group = @document.passages_for(node_id, include_descendants: true)
          next if group.empty?

          groups << { passages: group, heading: true, node_id: node_id }
          group.each { |passage| used << passage.id }
        end

        current = []
        passages.each do |passage|
          next if used.include?(passage.id)
          next if markers_for(passage).empty?

          if current.empty? || contiguous?(current.last, passage)
            current << passage
          else
            groups << { passages: current, heading: false, node_id: current.first.node_id }
            current = [passage]
          end
        end
        groups << { passages: current, heading: false, node_id: current.first.node_id } unless current.empty?
        groups
      end

      def contiguous?(left, right)
        left.node_id == right.node_id &&
          left.ordinal + 1 == right.ordinal &&
          left.chapter_path == right.chapter_path
      end

      def markers_for(passage)
        MARKERS.filter_map do |pattern|
          match = passage.text.match(pattern)
          match && match[0].downcase.strip
        end.uniq
      end

      def heading_marker?(passage)
        chapter = passage.chapter_path.last
        return false if chapter.nil? || chapter.empty?

        LanguageData.case_heading_patterns.any? { |pattern| chapter.match?(pattern) }
      end

      def build_case(group)
        passages = group[:passages].sort_by(&:ordinal)
        first = passages.first
        last = passages.last
        return nil unless first

        markers = passages.flat_map { |passage| markers_for(passage) }.uniq
        linked_entity_ids = passages.flat_map do |passage|
          (@mentions_by_passage[passage.id] || []).map(&:entity_id)
        end.uniq

        Case.new(
          id: "case_#{Digest::SHA1.hexdigest("#{@document.id}:#{first.id}:#{last.id}")[0, 12]}",
          document_id: @document.id,
          passage_id: first.id,
          passage_ids: passages.map(&:id),
          node_id: first.node_id,
          chapter_path: first.chapter_path,
          title: title_for(first, group[:heading]),
          kind: kind_for(markers, passages),
          markers: markers,
          text: passages.map(&:text).join("\n\n"),
          citation: Domain::Citation.build(document: @document, passage: first),
          linked_entity_ids: linked_entity_ids,
          confidence: confidence_for(markers, group[:heading], passages.length),
          method: "marker",
          start_char: first.start_char,
          end_char: last.end_char
        )
      end

      def kind_for(markers, passages)
        text = "#{markers.join(" ")} #{passages.map(&:text).join(" ")}"
        LanguageData.case_kind_patterns.each do |kind, patterns|
          return kind if patterns.any? { |pattern| text.match?(pattern) }
        end

        "example"
      end

      def title_for(passage, heading)
        chapter = passage.chapter_path.last.to_s.strip.sub(/\s*\[\d+\]\s*\z/, "")
        return chapter if heading && !chapter.empty?
        return Bookworm::I18n.t("cases.title_with_chapter", chapter: chapter) unless chapter.empty?

        Bookworm::I18n.t("cases.default_title")
      end

      def confidence_for(markers, heading, passage_count)
        return 0.9 if markers.length > 1 || passage_count > 1
        return 0.8 if heading

        0.7
      end
    end
  end
end
