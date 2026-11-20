# frozen_string_literal: true

require "i18n"

module Bookworm
  module I18n
    LOCALES = %i[en ru].freeze
    DEFAULT_LOCALE = :en

    module_function

    def setup!(locale: nil)
      ::I18n.load_path |= Dir[File.expand_path("locales/*.yml", __dir__)]
      ::I18n.available_locales = LOCALES
      ::I18n.default_locale = DEFAULT_LOCALE
      ::I18n.enforce_available_locales = true

      selected = (locale || ENV["BOOKWORM_LOCALE"] || system_locale).to_s.to_sym
      ::I18n.locale = LOCALES.include?(selected) ? selected : DEFAULT_LOCALE
    end

    def t(key, **options)
      ::I18n.t(key, **options)
    end

    def locale
      ::I18n.locale
    end

    def all(key)
      LOCALES.flat_map { |locale| Array(::I18n.t(key, locale: locale, default: [])) }.uniq
    end

    def for_locale(locale, key)
      Array(::I18n.t(key, locale: locale.to_sym, default: []))
    end

    def hash_for_all(key)
      LOCALES.each_with_object({}) do |locale, result|
        data = ::I18n.t(key, locale: locale, default: {})
        next unless data.is_a?(Hash)

        data.each do |name, values|
          name_key = name.to_s
          result[name_key] ||= []
          result[name_key].concat(Array(values))
        end
      end
    end

    def system_locale
      language = ENV["LANG"].to_s.split(".").first.to_s.split("_").first
      language == "ru" ? :ru : :en
    end
  end
end
