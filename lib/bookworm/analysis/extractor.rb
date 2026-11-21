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
      MAX_KEYPHRASE_CHARS = 120_000
      NAME_CASE_ENDINGS = %w[ами ями ого его ому ему ыми ими ом ем ой ей ах ях а я у ю е ы и].freeze
      KEYPHRASE_NOISE_TOKENS = %w[
        одно один одна одни двух два две трех три четыре пять несколько много мало
        это этот эта эти этого этой этих тот та те того той тех
        что кто как который которая которое которые которого которой которых
        все всё свои свой своя свои своего своей своих
        его ее их наш наша наше наши нашего нашей наших
        ваш ваша ваше ваши вашего вашей ваших
        данный данная данное данные данной данного данных
        данный необходимы необходимый необходимая необходимое необходимые необходимых
        новый новая новое новые новых новую
        серьезный серьезная серьезное серьезные серьезных
        последний последняя последнее последние последних
        таким такой такая такое такие такого
        права право защищены
        в во на с со к ко у о об обо по из от до за под над без через между
        среди около вокруг после перед при про для а но и или не
      ].freeze
      STOP_KEYPHRASE_WORDS = LanguageData.stopwords.to_set.freeze
      VERB_LIKE_TOKEN = /(?:ться|тся|ать|ять|ить|еть|ыть|уть|оть|ся|сь|ют|ут|ат|ят|[аяеи]ет|ует|юет|ишь|ешь|ете|ите|ал|ала|ало|али|ил|ила|ило|или|ыл|ыла|ыло|ыли|ана|ано|аны|ена|ено|ены)\z/u

      def initialize(document)
        @document = document
      end

      def call
        entity_data = {}
        mentions = []
        @keyphrases = extract_keyphrases(@document.full_text)
        @keyphrase_regex = build_keyphrase_regex(@keyphrases)

        @document.passages.each do |passage|
          extract_passage_entities(passage, entity_data, mentions)
        end

        entities = build_entities(entity_data, mentions)
        entities, mentions = merge_name_variants(entities, mentions)
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
            type: "term", source: "quoted", used_ranges: used_ranges,
            allow_sentence_start: true
          )
        end

        text.to_enum(:scan, ACRONYM).each do
          match = Regexp.last_match
          add_entity(
            entity_data, mentions, passage, match[0],
            start_char: match.begin(0), end_char: match.end(0),
            type: "acronym", source: "acronym", used_ranges: used_ranges,
            allow_sentence_start: true
          )
        end

        [LATIN_NAME, CYRILLIC_NAME].each do |pattern|
          text.to_enum(:scan, pattern).each do
            match = Regexp.last_match
            add_entity(
              entity_data, mentions, passage, match[0],
              start_char: match.begin(0), end_char: match.end(0),
              type: "proper_noun", source: "proper_noun", used_ranges: used_ranges,
              allow_sentence_start: false
            )
          end
        end

        return unless @keyphrase_regex

        text.to_enum(:scan, @keyphrase_regex).each do
          match = Regexp.last_match
          add_entity(
            entity_data, mentions, passage, match[0],
            start_char: match.begin(0), end_char: match.end(0),
            type: "term", source: "keyphrase", used_ranges: used_ranges,
            allow_sentence_start: true
          )
        end
      end

      def extract_keyphrases(text)
        require "rake_text"

        sample = keyphrase_sample(text)
        scores = RakeText::Engine.new(LanguageData.rake_stoplist_path).analyse(sample)
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

      def keyphrase_sample(text)
        headings = @document.nodes.map(&:title).compact.reject(&:empty?).join(". ")
        content = text.to_s
        return "#{headings}\n\n#{content}" if content.length <= MAX_KEYPHRASE_CHARS

        part = MAX_KEYPHRASE_CHARS / 3
        middle_start = [(content.length / 2) - (part / 2), 0].max
        samples = [
          content[0, part],
          content[middle_start, part],
          content[-part, part]
        ].compact
        "#{headings}\n\n#{samples.join("\n\n")}"
      end

      def build_keyphrase_regex(phrases)
        patterns = phrases.sort_by { |phrase| -phrase.length }.map { |phrase| phrase_regex(phrase) }
        patterns.empty? ? nil : Regexp.union(patterns)
      end

      def phrase_regex(phrase)
        parts = phrase.split(/\s+/).map { |part| Regexp.escape(part) }
        Regexp.new("\\b#{parts.join("\\s+")}\\b", Regexp::IGNORECASE)
      end

      def add_entity(entity_data, mentions, passage, raw_name, start_char:, end_char:, type:, source:, used_ranges:, allow_sentence_start:)
        return if overlaps?(used_ranges, start_char, end_char)

        name = clean_name(raw_name)
        return if name.empty?

        normalized = normalize_name(name)
        return if normalized.empty? || STOP_ENTITIES.include?(normalized)
        return if normalized.match?(/\A\d+\z/)
        return if name.length > 80
        return if type == "acronym" && name.length >= 6 && !name.match?(/\d/)
        if type == "term" && source == "keyphrase"
          tokens = normalized.split
          return if name.length < 4
          return if tokens.all? { |token| STOP_ENTITIES.include?(token) }
          return if tokens.any? do |token|
            STOP_ENTITIES.include?(token) ||
              STOP_KEYPHRASE_WORDS.include?(token) ||
              KEYPHRASE_NOISE_TOKENS.include?(token)
          end
          return if tokens.any? { |token| token.match?(/\A\d+\z/) || token.match?(VERB_LIKE_TOKEN) }
        end
        return if !allow_sentence_start && name.split.length == 1 && sentence_start?(passage.text, start_char)

        used_ranges << [start_char, end_char]
        key = type == "proper_noun" ? canonical_proper_name(name) : normalized
        key = normalized if key.empty?
        entity_id = "ent_#{Digest::SHA1.hexdigest(key)[0, 12]}"
        entry = entity_data[key] ||= {
          id: entity_id,
          normalized: normalized,
          surfaces: Hash.new(0),
          type: type,
          source: source,
          mentions: []
        }
        entry[:source] = "quoted" if source == "quoted"
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
        entity_data.each_with_object({}) do |(_key, entry), result|
          mention_count = counts[entry[:id]] || entry[:mentions].length
          next if entry[:source] == "keyphrase" && mention_count < 2

          name = entry[:surfaces].max_by { |surface, count| [count, surface.length] }.first
          result[entry[:id]] = Entity.new(
            id: entry[:id],
            name: name,
            normalized: normalize_name(name),
            type: entry[:type],
            aliases: entry[:surfaces].keys,
            mention_count: counts[entry[:id]] || entry[:mentions].length,
            document_ids: [@document.id]
          )
        end
      end

      def merge_name_variants(entities, mentions)
        mentions = mentions.select { |mention| entities.key?(mention.entity_id) }
        groups = []
        entities.values.sort_by { |entity| [-entity.mention_count, entity.name.length] }.each do |entity|
          group = groups.find { |candidate| name_variant?(candidate.first, entity) }
          group ? group << entity : groups << [entity]
        end
        return [entities, mentions] if groups.all? { |group| group.length == 1 }

        mapping = {}
        merged = {}
        groups.each do |group|
          canonical = group.first
          group.each { |entity| mapping[entity.id] = canonical.id }
          merged[canonical.id] = Entity.new(
            id: canonical.id,
            name: canonical.name,
            normalized: canonical.normalized,
            type: canonical.type,
            aliases: group.flat_map(&:aliases).uniq,
            mention_count: group.sum(&:mention_count),
            document_ids: group.flat_map(&:document_ids).uniq
          )
        end
        mentions.each do |mention|
          mention.entity_id = mapping[mention.entity_id] if mapping[mention.entity_id]
        end
        [merged, mentions]
      end

      def name_variant?(left, right)
        return false unless left.type == "proper_noun" && right.type == "proper_noun"
        return false if left.normalized.include?(" ") || right.normalized.include?(" ")
        return false if left.normalized.length < 4 || right.normalized.length < 4
        return false unless left.normalized[0, 2] == right.normalized[0, 2]

        Search::Trigram.similarity(left.normalized, right.normalized) >= 0.72
      end

      def canonical_proper_name(name)
        normalize_name(name).split.map { |token| canonical_name_token(token) }.join(" ")
      end

      def canonical_name_token(token)
        return token if token.length < 4 || token.match?(/\d/)

        value = token.dup
        NAME_CASE_ENDINGS.each do |ending|
          next unless value.end_with?(ending)
          next if value.length - ending.length < 3

          value = value[0...-ending.length]
          break
        end
        value = "#{value[0...-2]}л" if value.length >= 4 && value.end_with?("ел")
        value
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
