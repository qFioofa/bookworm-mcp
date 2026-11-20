# frozen_string_literal: true

require "digest"
require "set"

module Bookworm
  module Analysis
    class Extractor
      STOP_ENTITIES = LanguageData.entity_stopwords.to_set.freeze
      LEADING_ARTICLES = LanguageData.leading_articles.map { |article| Regexp.escape(article) }.join("|")
      NAME_CONNECTORS = LanguageData.name_connectors.map { |connector| Regexp.escape(connector) }.join("|")

      QUOTED = /"([^"\n]{2,80})"|«([^»\n]{2,80})»|“([^”\n]{2,80})”/u
      ACRONYM = /\b(?:[A-Z]{2,8}|[А-ЯЁ]{2,8})\b/u
      LATIN_NAME = /\b[A-Z][A-Za-z0-9'’\-]*(?:\s+(?:#{NAME_CONNECTORS})?\s*[A-Z][A-Za-z0-9'’\-]*){0,4}\b/u
      CYRILLIC_NAME = /\b[А-ЯЁ][а-яёА-ЯЁ0-9'’\-]*(?:\s+[А-ЯЁ][а-яёА-ЯЁ0-9'’\-]*){0,4}\b/u
      SENTENCE_END = /[.!?…]+(?=\s|\z)/u

      CUES = LanguageData.relation_cues

      MAX_RELATIONS = 2000

      def initialize(document)
        @document = document
      end

      def call
        entity_data = {}
        mentions = []
        @keyphrases = extract_keyphrases(@document.full_text)

        @document.passages.each do |passage|
          extract_passage_entities(passage, entity_data, mentions)
        end

        entities = build_entities(entity_data, mentions)
        relations = build_relations(mentions)
        cases = CaseExtractor.new(@document, mentions).call

        Graph.new(
          document: @document,
          entities: entities,
          mentions: mentions,
          relations: relations,
          cases: cases
        )
      end

      private

      def extract_passage_entities(passage, entity_data, mentions)
        text = passage.text
        used_ranges = []

        text.to_enum(:scan, QUOTED).each do
          match = Regexp.last_match
          name = match.captures.compact.first
          next unless name

          add_entity(
            entity_data, mentions, passage, name,
            start_char: match.begin(0), end_char: match.end(0),
            type: "term", used_ranges: used_ranges, allow_sentence_start: true
          )
        end

        text.to_enum(:scan, ACRONYM).each do
          match = Regexp.last_match
          add_entity(
            entity_data, mentions, passage, match[0],
            start_char: match.begin(0), end_char: match.end(0),
            type: "acronym", used_ranges: used_ranges, allow_sentence_start: true
          )
        end

        [LATIN_NAME, CYRILLIC_NAME].each do |pattern|
          text.to_enum(:scan, pattern).each do
            match = Regexp.last_match
            add_entity(
              entity_data, mentions, passage, match[0],
              start_char: match.begin(0), end_char: match.end(0),
              type: "proper_noun", used_ranges: used_ranges, allow_sentence_start: false
            )
          end
        end

        @keyphrases.each do |phrase|
          text.to_enum(:scan, phrase_regex(phrase)).each do
            match = Regexp.last_match
            add_entity(
              entity_data, mentions, passage, match[0],
              start_char: match.begin(0), end_char: match.end(0),
              type: "term", used_ranges: used_ranges, allow_sentence_start: true
            )
          end
        end
      end

      def extract_keyphrases(text)
        require "rake_text"

        scores = RakeText::Engine.new(LanguageData.rake_stoplist_path).analyse(text)
        candidates = scores.select do |phrase, score|
          word_count = phrase.split(/\s+/).length
          word_count.between?(2, 4) && score.to_f >= 4.0
        end

        selected = []
        candidates.sort_by { |phrase, score| [phrase.split(/\s+/).length, -score.to_f] }.each do |phrase, _score|
          normalized = normalize_name(phrase)
          next if normalized.empty?
          next if selected.any? { |kept| normalized.include?(normalize_name(kept)) }

          selected << phrase
          break if selected.length >= 60
        end
        selected
      rescue LoadError, StandardError
        []
      end

      def phrase_regex(phrase)
        parts = phrase.split(/\s+/).map { |part| Regexp.escape(part) }
        Regexp.new("\\b#{parts.join("\\s+")}\\b", Regexp::IGNORECASE)
      end

      def add_entity(entity_data, mentions, passage, raw_name, start_char:, end_char:, type:, used_ranges:, allow_sentence_start:)
        return if overlaps?(used_ranges, start_char, end_char)

        name = clean_name(raw_name)
        return if name.empty?

        normalized = normalize_name(name)
        return if normalized.empty? || STOP_ENTITIES.include?(normalized)
        return if normalized.match?(/\A\d+\z/)
        return if name.length > 80
        return if !allow_sentence_start && name.split.length == 1 && sentence_start?(passage.text, start_char)

        used_ranges << [start_char, end_char]
        entity_id = "ent_#{Digest::SHA1.hexdigest(normalized)[0, 12]}"
        entry = entity_data[normalized] ||= {
          id: entity_id,
          normalized: normalized,
          surfaces: Hash.new(0),
          type: type,
          mentions: []
        }
        entry[:surfaces][name] += 1
        entry[:type] = better_type(entry[:type], type)
        mention = Mention.new(
          entity_id: entity_id,
          document_id: @document.id,
          passage_id: passage.id,
          surface: name,
          start_char: start_char,
          end_char: end_char
        )
        entry[:mentions] << mention
        mentions << mention
      end

      def build_entities(entity_data, mentions)
        counts = mentions.group_by(&:entity_id).transform_values(&:length)
        entity_data.each_with_object({}) do |(normalized, entry), result|
          name = entry[:surfaces].max_by { |surface, count| [count, surface.length] }.first
          result[entry[:id]] = Entity.new(
            id: entry[:id],
            name: name,
            normalized: normalized,
            type: entry[:type],
            aliases: entry[:surfaces].keys,
            mention_count: counts[entry[:id]] || entry[:mentions].length,
            document_ids: [@document.id]
          )
        end
      end

      def build_relations(mentions)
        by_passage = mentions.group_by(&:passage_id)
        relation_map = {}

        @document.passages.each do |passage|
          passage_mentions = (by_passage[passage.id] || []).sort_by(&:start_char)
          next if passage_mentions.length < 2

          direct_pairs = Set.new
          sentence_ranges(passage.text).each do |sentence_start, sentence_end|
            in_sentence = passage_mentions.select do |mention|
              mention.start_char >= sentence_start && mention.end_char <= sentence_end
            end
            in_sentence = in_sentence.uniq(&:entity_id).first(20)

            in_sentence.each_with_index do |left, index|
              in_sentence[(index + 1)..].to_a.each do |right|
                between = passage.text[left.end_char...right.start_char].to_s
                predicate = cue_for(between)
                next unless predicate

                evidence = evidence_for(passage, sentence_start, sentence_end)
                add_relation(
                  relation_map,
                  left.entity_id,
                  right.entity_id,
                  predicate,
                  directed: true,
                  confidence: 0.85,
                  evidence: evidence
                )
                direct_pairs << [left.entity_id, right.entity_id].sort
              end
            end
          end

          unique_entities = passage_mentions.map(&:entity_id).uniq
          pairs = unique_entities.each_cons(2)

          pairs.each do |left, right|
            next if left == right
            next if direct_pairs.include?([left, right].sort)

            add_relation(
              relation_map,
              left,
              right,
              "CO_OCCURS",
              directed: false,
              confidence: 0.4,
              evidence: evidence_for(passage, 0, passage.text.length)
            )
          end
        end

        relation_map.values
                    .sort_by { |relation| [-relation.confidence.to_f, -relation.count.to_i] }
                    .first(MAX_RELATIONS)
      end

      def add_relation(map, source_id, target_id, predicate, directed:, confidence:, evidence:)
        key = if directed
                [source_id, target_id, predicate]
              else
                [[source_id, target_id].sort, predicate]
              end

        existing = map[key]
        if existing
          existing.count += 1
          existing.confidence = [existing.confidence, confidence].max
          existing.evidence << evidence if existing.evidence.length < 3
          return
        end

        map[key] = Relation.new(
          id: "rel_#{Digest::SHA1.hexdigest(key.flatten.join("|"))[0, 12]}",
          source_id: source_id,
          target_id: target_id,
          predicate: predicate,
          directed: directed,
          count: 1,
          confidence: confidence,
          method: "rule",
          evidence: [evidence]
        )
      end

      def evidence_for(passage, start_char, end_char)
        {
          citation: Domain::Citation.build(document: @document, passage: passage),
          quote: passage.text[start_char...end_char].to_s[0, 500],
          start_char: passage.start_char + start_char,
          end_char: passage.start_char + end_char
        }
      end

      def cue_for(text)
        CUES.each do |predicate, patterns|
          return predicate if patterns.any? { |pattern| text.match?(pattern) }
        end
        nil
      end

      def sentence_ranges(text)
        ranges = []
        start = 0
        text.to_enum(:scan, SENTENCE_END).each do
          match = Regexp.last_match
          finish = match.end(0)
          ranges << [start, finish]
          start = finish
          start += 1 while start < text.length && text[start].match?(/\s/)
        end
        ranges << [start, text.length] if start < text.length
        ranges
      end

      def clean_name(name)
        name.to_s.unicode_normalize(:nfkc).strip
            .sub(/\A(?:#{LEADING_ARTICLES})\s+/i, "")
            .gsub(/\s+/, " ")
            .gsub(/\A[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/u, "")
            .strip
      end

      def normalize_name(name)
        name.to_s.downcase.tr("ё", "е")
            .gsub(/[^\p{L}\p{N}\s\-]/u, " ")
            .gsub(/\s+/, " ")
            .strip
      end

      def better_type(left, right)
        priority = { "proper_noun" => 1, "acronym" => 2, "term" => 3 }
        priority[right].to_i > priority[left].to_i ? right : left
      end

      def overlaps?(ranges, start_char, end_char)
        ranges.any? { |left, right| start_char < right && end_char > left }
      end

      def sentence_start?(text, start_char)
        return true if start_char.zero?

        text[0...start_char].match?(/[.!?…"”»]\s*\z/)
      end
    end
  end
end
