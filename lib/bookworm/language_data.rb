# frozen_string_literal: true

require "tmpdir"

module Bookworm
  module LanguageData
    module_function

    def stopwords
      @stopwords ||= Bookworm::I18n.all("search.stopwords").map { |word| word.to_s.downcase }.uniq.freeze
    end

    def stemmer_suffixes(locale)
      @stemmer_suffixes ||= {}
      @stemmer_suffixes[locale.to_sym] ||= begin
        Bookworm::I18n.for_locale(locale, "search.stemmer.suffixes")
                       .map(&:to_s)
                       .sort_by { |suffix| -suffix.length }
                       .freeze
      end
    end

    def entity_stopwords
      @entity_stopwords ||= Bookworm::I18n.all("analysis.entity_stopwords")
                                          .map { |word| word.to_s.downcase }
                                          .uniq
                                          .freeze
    end

    def leading_articles
      @leading_articles ||= Bookworm::I18n.all("analysis.leading_articles").map(&:to_s).freeze
    end

    def name_connectors
      @name_connectors ||= Bookworm::I18n.all("analysis.name_connectors").map(&:to_s).freeze
    end

    def relation_cues
      @relation_cues ||= Bookworm::I18n.hash_for_all("analysis.relation_cues").transform_values do |patterns|
        patterns.uniq.map { |pattern| Regexp.new(pattern, Regexp::IGNORECASE) }
      end.freeze
    end

    def case_markers
      @case_markers ||= Bookworm::I18n.all("analysis.case_markers")
                                     .map { |pattern| Regexp.new(pattern, Regexp::IGNORECASE) }
                                     .freeze
    end

    def case_heading_patterns
      @case_heading_patterns ||= Bookworm::I18n.all("analysis.case_heading_patterns")
                                               .map { |pattern| Regexp.new(pattern, Regexp::IGNORECASE) }
                                               .freeze
    end

    def case_kind_patterns
      @case_kind_patterns ||= Bookworm::I18n.hash_for_all("analysis.case_kind_patterns").transform_values do |patterns|
        patterns.uniq.map { |pattern| Regexp.new(pattern, Regexp::IGNORECASE) }
      end.freeze
    end

    def heading_patterns
      @heading_patterns ||= Bookworm::I18n.all("ingest.heading_patterns")
                                          .map { |pattern| Regexp.new(pattern, Regexp::IGNORECASE) }
                                          .freeze
    end

    def rake_stopwords
      @rake_stopwords ||= (
        stopwords +
        entity_stopwords +
        Bookworm::I18n.all("analysis.rake_stopwords").map { |word| word.to_s.downcase }
      ).uniq.freeze
    end

    def rake_stoplist_path
      @rake_stoplist_path ||= begin
        path = File.join(Dir.tmpdir, "bookworm-stopwords-#{Process.pid}.txt")
        File.write(path, rake_stopwords.join("\n"))
        path
      end
    end
  end
end
