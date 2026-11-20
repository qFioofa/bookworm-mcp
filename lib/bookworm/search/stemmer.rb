# frozen_string_literal: true

module Bookworm
  module Search
    module Stemmer

      module_function

      def stem(word)
        value = word.to_s.downcase.tr("ё", "е")
        return value if value.length <= 3

        if value.match?(/\A[а-я]+\z/)
          LanguageData.stemmer_suffixes(:ru).each do |suffix|
            next unless value.end_with?(suffix)
            next unless value.length - suffix.length >= 4

            return value[0...-suffix.length]
          end
        else
          LanguageData.stemmer_suffixes(:en).each do |suffix|
            next unless value.end_with?(suffix)
            next if value.length - suffix.length < 4
            next if value.end_with?("ss", "us", "is") && suffix == "s"

            return value[0...-suffix.length]
          end
        end

        value
      end
    end
  end
end
