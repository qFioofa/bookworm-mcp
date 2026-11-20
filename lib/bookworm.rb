# frozen_string_literal: true

require "mcp"

require_relative "bookworm/version"
require_relative "bookworm/errors"
require_relative "bookworm/config"
require_relative "bookworm/i18n"

Bookworm::I18n.setup!
require_relative "bookworm/language_data"
require_relative "bookworm/util/text"

require_relative "bookworm/domain/node"
require_relative "bookworm/domain/passage"
require_relative "bookworm/domain/document"
require_relative "bookworm/domain/citation"

require_relative "bookworm/analysis/models"
require_relative "bookworm/analysis/graph"
require_relative "bookworm/analysis/case_extractor"
require_relative "bookworm/analysis/extractor"
require_relative "bookworm/analysis/plantuml"

require_relative "bookworm/ingest/block"
require_relative "bookworm/ingest/draft"
require_relative "bookworm/ingest/chunker"
require_relative "bookworm/ingest/document_builder"
require_relative "bookworm/ingest/adapters/text"
require_relative "bookworm/ingest/adapters/epub"
require_relative "bookworm/ingest/adapters/pdf"
require_relative "bookworm/ingest/adapters/fb2"
require_relative "bookworm/ingest/adapters/djvu"
require_relative "bookworm/ingest/adapters/registry"
require_relative "bookworm/ingest/pipeline"

require_relative "bookworm/store/memory_store"

require_relative "bookworm/search/stemmer"
require_relative "bookworm/search/tokenizer"
require_relative "bookworm/search/query_parser"
require_relative "bookworm/search/trigram"
require_relative "bookworm/search/index"
require_relative "bookworm/search/snippet"
require_relative "bookworm/search/engine"

require_relative "bookworm/app"

require_relative "bookworm/mcp/schemas"
require_relative "bookworm/mcp/responder"
require_relative "bookworm/mcp/tools"
require_relative "bookworm/mcp/server"
require_relative "bookworm/mcp/cli"
