# frozen_string_literal: true

module Bookworm
  module Analysis
    Entity = Struct.new(
      :id, :name, :normalized, :type, :aliases, :mention_count, :document_ids,
      keyword_init: true
    ) do
      def to_h
        {
          entity_id: id,
          name: name,
          type: type,
          aliases: aliases,
          mention_count: mention_count,
          document_count: document_ids.length,
          document_ids: document_ids
        }
      end
    end

    Mention = Struct.new(
      :entity_id, :document_id, :passage_id, :surface, :start_char, :end_char,
      keyword_init: true
    ) do
      def to_h
        {
          entity_id: entity_id,
          document_id: document_id,
          passage_id: passage_id,
          surface: surface,
          start_char: start_char,
          end_char: end_char
        }
      end
    end

    Relation = Struct.new(
      :id, :source_id, :target_id, :predicate, :directed, :count, :confidence,
      :method, :evidence,
      keyword_init: true
    ) do
      def to_h(include_evidence: true)
        payload = {
          relation_id: id,
          source_id: source_id,
          target_id: target_id,
          predicate: predicate,
          directed: directed,
          count: count,
          confidence: confidence,
          method: method
        }
        payload[:evidence] = evidence if include_evidence
        payload
      end
    end

    Case = Struct.new(
      :id, :document_id, :passage_id, :passage_ids, :node_id, :chapter_path,
      :title, :kind, :markers, :text, :citation, :linked_entity_ids,
      :confidence, :method, :start_char, :end_char,
      keyword_init: true
    ) do
      def to_h(include_text: true)
        payload = {
          case_id: id,
          document_id: document_id,
          passage_id: passage_id,
          passage_ids: passage_ids || Array(passage_id),
          node_id: node_id,
          chapter_path: chapter_path || citation[:chapter_path],
          title: title,
          kind: kind,
          kind_label: Bookworm::I18n.t("cases.kind.#{kind}", default: kind),
          markers: markers,
          citation: citation,
          range: {
            start_char: start_char || citation[:start_char],
            end_char: end_char || citation[:end_char]
          },
          linked_entity_ids: linked_entity_ids,
          confidence: confidence,
          method: method
        }
        payload[:text] = text if include_text
        payload
      end
    end
  end
end
