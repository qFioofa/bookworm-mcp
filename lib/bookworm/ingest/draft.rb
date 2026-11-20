# frozen_string_literal: true

module Bookworm
  module Ingest
    Draft = Struct.new(:title, :authors, :language, :format, :blocks, :metadata, keyword_init: true)
  end
end
