# frozen_string_literal: true

require "set"

module Bookworm
  module Search
    module Trigram
      module_function

      def grams(text)
        normalized = Util::Text.normalize_for_match(text)
        padded = "  #{normalized}  "
        return Set.new if padded.length < 3

        result = Set.new
        (0..(padded.length - 3)).each { |index| result << padded[index, 3] }
        result
      end

      def similarity(left, right)
        left_grams = grams(left)
        right_grams = grams(right)
        return 0.0 if left_grams.empty? || right_grams.empty?

        intersection = (left_grams & right_grams).length
        (2.0 * intersection) / (left_grams.length + right_grams.length)
      end
    end
  end
end
