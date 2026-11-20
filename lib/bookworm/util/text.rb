# frozen_string_literal: true

require "cgi"
require "digest"

module Bookworm
  module Util
    module Text
      module_function

      def normalize_newlines(text)
        text.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
      end

      def collapse_whitespace(text)
        text.to_s.gsub(/[ \t]+/, " ").gsub(/\n{3,}/, "\n\n").strip
      end

      def normalize_for_match(text)
        collapse_whitespace(text.to_s.unicode_normalize(:nfkc).downcase.tr("ё", "е"))
      end

      def decode_entities(text)
        CGI.unescapeHTML(text.to_s)
      rescue StandardError
        text.to_s
      end

      def strip_inline_markdown(text)
        value = text.to_s.dup
        value.gsub!(/!\[([^\]]*)\]\([^)]+\)/, '\1')
        value.gsub!(/\[([^\]]+)\]\([^)]+\)/, '\1')
        value.gsub!(/`([^`]+)`/, '\1')
        value.gsub!(/(\*\*|__)(.*?)\1/, '\2')
        value.gsub!(/(\*|_)(.*?)\1/, '\2')
        value.gsub!(/~~(.*?)~~/, '\1')
        value
      end

      def detect_language(text)
        sample = text.to_s[0, 20_000]
        cyrillic = sample.scan(/\p{Cyrillic}/).length
        latin = sample.scan(/\p{Latin}/).length
        return "ru" if cyrillic.positive? && cyrillic >= latin
        return "en" if latin.positive?

        "und"
      end

      def sha256(value)
        Digest::SHA256.hexdigest(value.to_s)
      end

      def read_text_file(path)
        raw = File.binread(path)
        decode_bytes(raw)
      end

      def decode_bytes(raw)
        raw = raw.dup
        if raw.start_with?("\xEF\xBB\xBF".b)
          raw = raw.byteslice(3..) || +""
          return normalize_newlines(raw.force_encoding(Encoding::UTF_8))
        end
        if raw.start_with?("\xFF\xFE".b)
          return normalize_newlines(raw.byteslice(2..).force_encoding(Encoding::UTF_16LE).encode(Encoding::UTF_8))
        end
        if raw.start_with?("\xFE\xFF".b)
          return normalize_newlines(raw.byteslice(2..).force_encoding(Encoding::UTF_16BE).encode(Encoding::UTF_8))
        end

        utf8 = raw.force_encoding(Encoding::UTF_8)
        return normalize_newlines(utf8) if utf8.valid_encoding?

        windows = raw.force_encoding(Encoding::Windows_1251)
        if windows.valid_encoding?
          normalize_newlines(windows.encode(Encoding::UTF_8))
        else
          normalize_newlines(utf8.scrub)
        end
      end
    end
  end
end
