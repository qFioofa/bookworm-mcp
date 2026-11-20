# frozen_string_literal: true

require_relative "test_helper"

class I18nTest < Minitest::Test
  def teardown
    Bookworm::I18n.setup!(locale: "en")
  end

  def test_russian_locale_is_loaded
    Bookworm::I18n.setup!(locale: "ru")

    assert_equal :ru, Bookworm::I18n.locale
    assert_equal "Поиск", Bookworm::I18n.t("tools.search.title")
    assert_equal "Ресурс не найден", Bookworm::I18n.t("errors.not_found")
    assert_equal "Пример", Bookworm::I18n.t("cases.kind.example")
  end

  def test_language_data_is_loaded_from_locales
    assert_includes Bookworm::LanguageData.stopwords, "the"
    assert_includes Bookworm::LanguageData.stopwords, "и"
    assert_includes Bookworm::LanguageData.stemmer_suffixes(:ru), "ами"
    assert Bookworm::LanguageData.relation_cues["CAUSES"].any? { |pattern| pattern.match?("вызывает") }
    assert Bookworm::LanguageData.case_markers.any? { |pattern| pattern.match?("например") }
  end

  def test_english_locale_is_default
    Bookworm::I18n.setup!(locale: "en")

    assert_equal "Search", Bookworm::I18n.t("tools.search.title")
    assert_equal "Resource not found", Bookworm::I18n.t("errors.not_found")
  end
end
