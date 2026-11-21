# frozen_string_literal: true

module Bookworm
  module MCP
    module Tools
      def self.app(server_context)
        app = server_context && server_context[:app]
        raise ValidationError.new("Server context is missing the application") unless app

        app
      end

      class IngestBookTool < ::MCP::Tool
        tool_name "ingest_book"
        title Bookworm::I18n.t("tools.ingest_book.title")
        description Bookworm::I18n.t("tools.ingest_book.description")
        annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
        input_schema(
          type: "object",
          properties: {
            path: Schemas.string(:path),
            title: Schemas.string(:title_override),
            replace: Schemas.boolean(:replace_document)
          },
          required: ["path"]
        )
        output_schema(Schemas.ingest_output)

        def self.call(path:, server_context:, title: nil, replace: false)
          Responder.call do
            result = Tools.app(server_context).ingest_book_result(path, title: title, replace: replace)
            document = result.document
            {
              document: document.to_h,
              cached: result.cached,
              first_passage_id: document.passages.first&.id
            }
          end
        end
      end

      class IngestBooksTool < ::MCP::Tool
        tool_name "ingest_books"
        title Bookworm::I18n.t("tools.ingest_books.title")
        description Bookworm::I18n.t("tools.ingest_books.description")
        annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
        input_schema(
          type: "object",
          properties: {
            paths: { type: "array", items: { type: "string" }, description: Schemas.description(:paths_batch) },
            title: Schemas.string(:title_override),
            replace: Schemas.boolean(:replace_document)
          },
          required: ["paths"]
        )
        output_schema(Schemas.ingest_books_output)

        def self.call(paths:, server_context:, title: nil, replace: false)
          Responder.call do
            Tools.app(server_context).ingest_books(paths, title: title, replace: replace)
          end
        end
      end

      class IngestTextTool < ::MCP::Tool
        tool_name "ingest_text"
        title Bookworm::I18n.t("tools.ingest_text.title")
        description Bookworm::I18n.t("tools.ingest_text.description")
        annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
        input_schema(
          type: "object",
          properties: {
            text: Schemas.string(:text_inline_optional),
            source_path: Schemas.string(:source_path_text),
            source_url: Schemas.string(:source_url_text),
            title: Schemas.string(:title_optional),
            format: { type: "string", enum: %w[plain markdown] },
            language: Schemas.string(:language_optional),
            ttl_seconds: Schemas.integer(:ttl_seconds, minimum: 0)
          }
        )
        output_schema(Schemas.ingest_output)

        def self.call(text: nil, server_context:, title: nil, format: nil, language: nil, ttl_seconds: nil, source_path: nil, source_url: nil)
          Responder.call do
            result = Tools.app(server_context).ingest_text_result(
              text,
              title: title,
              format: format,
              language: language,
              ttl_seconds: ttl_seconds,
              source_path: source_path,
              source_url: source_url
            )
            document = result.document
            {
              document: document.to_h,
              cached: result.cached,
              first_passage_id: document.passages.first&.id
            }
          end
        end
      end

      class ListDocumentsTool < ::MCP::Tool
        tool_name "list_documents"
        title Bookworm::I18n.t("tools.list_documents.title")
        description Bookworm::I18n.t("tools.list_documents.description")
        annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)
        input_schema(
          type: "object",
          properties: {
            kind: { type: "string", enum: %w[book text] },
            limit: Schemas.integer(:limit_documents, minimum: 1, maximum: 500)
          }
        )
        output_schema(Schemas.list_documents_output)

        def self.call(server_context:, kind: nil, limit: 100)
          Responder.call do
            Tools.app(server_context).list_documents(kind: kind, limit: limit)
          end
        end
      end

      class GetDocumentTool < ::MCP::Tool
        tool_name "get_document"
        title Bookworm::I18n.t("tools.get_document.title")
        description Bookworm::I18n.t("tools.get_document.description")
        annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)
        input_schema(
          type: "object",
          properties: { document_id: Schemas.string(:document_id) },
          required: ["document_id"]
        )
        output_schema(Schemas.document_output)

        def self.call(document_id:, server_context:)
          Responder.call do
            Tools.app(server_context).get_document(document_id)
          end
        end
      end

      class GetOutlineTool < ::MCP::Tool
        tool_name "get_outline"
        title Bookworm::I18n.t("tools.get_outline.title")
        description Bookworm::I18n.t("tools.get_outline.description")
        annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)
        input_schema(
          type: "object",
          properties: {
            document_id: Schemas.string(:document_id),
            node_id: Schemas.string(:node_id),
            depth: Schemas.integer(:depth_outline, minimum: 0, maximum: 10),
            max_nodes: Schemas.integer(:max_nodes_outline, minimum: 1, maximum: 1000),
            titles_only: Schemas.boolean(:titles_only)
          },
          required: ["document_id"]
        )
        output_schema(Schemas.outline_output)

        def self.call(document_id:, server_context:, node_id: nil, depth: 10, max_nodes: 200, titles_only: false)
          Responder.call do
            Tools.app(server_context).get_outline(
              document_id: document_id,
              node_id: node_id,
              depth: depth,
              max_nodes: max_nodes,
              titles_only: titles_only
            )
          end
        end
      end

      class ReadPassageTool < ::MCP::Tool
        tool_name "read_passage"
        title Bookworm::I18n.t("tools.read_passage.title")
        description Bookworm::I18n.t("tools.read_passage.description")
        annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)
        input_schema(
          type: "object",
          properties: {
            passage_id: Schemas.string(:passage_id),
            before: Schemas.integer(:before, minimum: 0, maximum: 20),
            after: Schemas.integer(:after, minimum: 0, maximum: 20),
            max_tokens: Schemas.integer(:max_tokens_passage, minimum: 1)
          },
          required: ["passage_id"]
        )
        output_schema(Schemas.read_passage_output)

        def self.call(passage_id:, server_context:, before: 1, after: 1, max_tokens: nil)
          Responder.call do
            Tools.app(server_context).read_passage(
              passage_id: passage_id,
              before: before,
              after: after,
              max_tokens: max_tokens
            )
          end
        end
      end

      class ReadChapterTool < ::MCP::Tool
        tool_name "read_chapter"
        title Bookworm::I18n.t("tools.read_chapter.title")
        description Bookworm::I18n.t("tools.read_chapter.description")
        annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)
        input_schema(
          type: "object",
          properties: {
            document_id: Schemas.string(:document_id),
            node_id: Schemas.string(:node_id_chapter),
            offset: Schemas.integer(:offset_chapter, minimum: 0),
            limit: Schemas.integer(:limit_chapter, minimum: 1, maximum: 200),
            max_tokens: Schemas.integer(:max_tokens_passage, minimum: 1),
            include_footnotes: Schemas.boolean(:include_footnotes)
          },
          required: %w[document_id node_id]
        )
        output_schema(Schemas.read_chapter_output)

        def self.call(document_id:, node_id:, server_context:, offset: 0, limit: 50, max_tokens: nil, include_footnotes: true)
          Responder.call do
            Tools.app(server_context).read_chapter(
              document_id: document_id,
              node_id: node_id,
              offset: offset,
              limit: limit,
              max_tokens: max_tokens,
              include_footnotes: include_footnotes
            )
          end
        end
      end

      class SearchTool < ::MCP::Tool
        tool_name "search"
        title Bookworm::I18n.t("tools.search.title")
        description Bookworm::I18n.t("tools.search.description")
        annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)
        input_schema(
          type: "object",
          properties: {
            query: Schemas.string(:query_search),
            document_id: Schemas.string(:document_id_search),
            text: Schemas.string(:inline_text_search),
            title: Schemas.string(:inline_title),
            format: { type: "string", enum: %w[plain markdown] },
            language: Schemas.string(:language_inline),
            mode: { type: "string", enum: %w[smart lexical exact fuzzy], default: "smart", description: Schemas.description(:mode_search) },
            k: Schemas.integer(:k, minimum: 1, maximum: 50),
            cursor: Schemas.string(:cursor),
            include_text: Schemas.boolean(:include_text),
            max_tokens: Schemas.integer(:max_tokens_text, minimum: 1),
            verbosity: { type: "string", enum: %w[full compact], default: "full", description: Schemas.description(:verbosity_search) },
            include_breakdown: Schemas.boolean(:include_breakdown),
            filters: {
              type: "object",
              properties: {
                kind: { type: "string", enum: %w[book text] },
                language: Schemas.string,
                node_id: Schemas.string,
                page_min: Schemas.integer,
                page_max: Schemas.integer
              }
            }
          },
          required: ["query"]
        )
        output_schema(Schemas.search_output)

        def self.call(
          query:, server_context:, document_id: nil, text: nil, title: nil,
          format: nil, language: nil, mode: "smart", k: 10, cursor: nil,
          include_text: false, max_tokens: nil, filters: nil,
          verbosity: "full", include_breakdown: true
        )
          Responder.call do
            raise ValidationError.new("Provide either document_id or text, not both") if document_id && text

            app = Tools.app(server_context)
            target_id = document_id
            if text
              document = app.ingest_text(text, title: title, format: format || "plain", language: language)
              target_id = document.id
            end

            app.search(
              query: query,
              document_id: target_id,
              mode: mode,
              k: k,
              cursor: cursor,
              include_text: include_text,
              filters: filters || {},
              max_tokens: max_tokens,
              verbosity: verbosity,
              include_breakdown: include_breakdown
            )
          end
        end
      end

      class FindQuoteTool < ::MCP::Tool
        tool_name "find_quote"
        title Bookworm::I18n.t("tools.find_quote.title")
        description Bookworm::I18n.t("tools.find_quote.description")
        annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)
        input_schema(
          type: "object",
          properties: {
            quote: Schemas.string(:quote),
            document_id: Schemas.string(:document_id_optional),
            text: Schemas.string(:inline_text_quote),
            title: Schemas.string(:inline_title),
            format: { type: "string", enum: %w[plain markdown] },
            language: Schemas.string(:language_inline),
            fuzzy: Schemas.boolean(:fuzzy),
            source: { type: "string", enum: %w[any book text], default: "any", description: Schemas.description(:source_quote) },
            max_results: Schemas.integer(:max_results, minimum: 1, maximum: 50)
          },
          required: ["quote"]
        )
        output_schema(Schemas.find_quote_output)

        def self.call(
          quote:, server_context:, document_id: nil, text: nil, title: nil,
          format: nil, language: nil, fuzzy: false, max_results: 10, source: "any"
        )
          Responder.call do
            raise ValidationError.new("Provide either document_id or text, not both") if document_id && text

            app = Tools.app(server_context)
            target_id = document_id
            if text
              document = app.ingest_text(text, title: title, format: format || "plain", language: language)
              target_id = document.id
            end

            app.find_quote(
              quote: quote,
              document_id: target_id,
              fuzzy: fuzzy,
              max_results: max_results,
              source: source
            )
          end
        end
      end

      class DeleteDocumentTool < ::MCP::Tool
        tool_name "delete_document"
        title Bookworm::I18n.t("tools.delete_document.title")
        description Bookworm::I18n.t("tools.delete_document.description")
        annotations(read_only_hint: false, destructive_hint: true, idempotent_hint: true, open_world_hint: false)
        input_schema(
          type: "object",
          properties: { document_id: Schemas.string(:document_id) },
          required: ["document_id"]
        )
        output_schema(Schemas.ingest_output)

        def self.call(document_id:, server_context:)
          Responder.call do
            document = Tools.app(server_context).remove_document(document_id)
            {
              document: document.to_h,
              first_passage_id: document.passages.first&.id
            }
          end
        end
      end

      class StatsTool < ::MCP::Tool
        tool_name "stats"
        title Bookworm::I18n.t("tools.stats.title")
        description Bookworm::I18n.t("tools.stats.description")
        annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)
        input_schema(
          type: "object",
          properties: { document_id: Schemas.string(:document_id_optional) }
        )
        output_schema(Schemas.stats_output)

        def self.call(server_context:, document_id: nil)
          Responder.call do
            Tools.app(server_context).stats(document_id: document_id)
          end
        end
      end


      class SearchEntitiesTool < ::MCP::Tool
        tool_name "search_entities"
        title Bookworm::I18n.t("tools.search_entities.title")
        description Bookworm::I18n.t("tools.search_entities.description")
        annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)
        input_schema(
          type: "object",
          properties: {
            query: Schemas.string(:query_entities),
            document_id: Schemas.string(:document_id_optional),
            type: { type: "string", enum: %w[proper_noun term acronym] },
            limit: Schemas.integer(:limit_entities, minimum: 1, maximum: 100)
          }
        )
        output_schema(Schemas.search_entities_output)

        def self.call(server_context:, query: nil, document_id: nil, type: nil, limit: 20)
          Responder.call do
            Tools.app(server_context).search_entities(
              query: query,
              document_id: document_id,
              type: type,
              limit: limit
            )
          end
        end
      end

      class GetEntityTool < ::MCP::Tool
        tool_name "get_entity"
        title Bookworm::I18n.t("tools.get_entity.title")
        description Bookworm::I18n.t("tools.get_entity.description")
        annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)
        input_schema(
          type: "object",
          properties: { entity_id: Schemas.string(:entity_id) },
          required: ["entity_id"]
        )
        output_schema(Schemas.get_entity_output)

        def self.call(entity_id:, server_context:)
          Responder.call do
            Tools.app(server_context).get_entity(entity_id)
          end
        end
      end

      class GetRelationsTool < ::MCP::Tool
        tool_name "get_relations"
        title Bookworm::I18n.t("tools.get_relations.title")
        description Bookworm::I18n.t("tools.get_relations.description")
        annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)
        input_schema(
          type: "object",
          properties: {
            entity_id: Schemas.string(:entity_id_optional),
            document_id: Schemas.string(:document_id_optional),
            depth: Schemas.integer(:depth_relations, minimum: 0, maximum: 5),
            predicates: {
              oneOf: [
                { type: "string" },
                { type: "array", items: { type: "string" } }
              ],
              description: Schemas.description(:predicates)
            },
            limit: Schemas.integer(:limit_edges, minimum: 1, maximum: 500),
            max_nodes: Schemas.integer(:max_nodes, minimum: 1, maximum: 200),
            min_confidence: Schemas.number(:min_confidence),
            format: { type: "string", enum: %w[json plantuml both], default: "json" },
            include_evidence: Schemas.boolean(:include_evidence),
            include_url: Schemas.boolean(:include_url)
          }
        )
        output_schema(Schemas.graph_output)

        def self.call(
          server_context:, entity_id: nil, document_id: nil, depth: 1, predicates: nil,
          limit: 100, max_nodes: 50, min_confidence: 0.5, format: "json",
          include_evidence: true, include_url: false
        )
          Responder.call do
            Tools.app(server_context).get_relations(
              entity_id: entity_id,
              document_id: document_id,
              depth: depth,
              predicates: predicates,
              limit: limit,
              max_nodes: max_nodes,
              min_confidence: min_confidence,
              format: format,
              include_evidence: include_evidence,
              include_url: include_url
            )
          end
        end
      end

      class GetLogicalChainTool < ::MCP::Tool
        tool_name "get_logical_chain"
        title Bookworm::I18n.t("tools.get_logical_chain.title")
        description Bookworm::I18n.t("tools.get_logical_chain.description")
        annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)
        input_schema(
          type: "object",
          properties: {
            start: Schemas.string(:start),
            finish: Schemas.string(:finish),
            document_id: Schemas.string(:document_id_optional),
            max_depth: Schemas.integer(:max_depth, minimum: 1, maximum: 10),
            min_confidence: Schemas.number(:min_confidence),
            format: { type: "string", enum: %w[json plantuml both], default: "json" },
            include_evidence: Schemas.boolean(:include_evidence),
            include_url: Schemas.boolean(:include_url)
          },
          required: %w[start finish]
        )
        output_schema(Schemas.logical_chain_output)

        def self.call(
          start:, finish:, server_context:, document_id: nil, max_depth: 4,
          min_confidence: 0.5, format: "json", include_evidence: true, include_url: false
        )
          Responder.call do
            Tools.app(server_context).get_logical_chain(
              start: start,
              finish: finish,
              document_id: document_id,
              max_depth: max_depth,
              min_confidence: min_confidence,
              format: format,
              include_evidence: include_evidence,
              include_url: include_url
            )
          end
        end
      end

      class FindCasesTool < ::MCP::Tool
        tool_name "find_cases"
        title Bookworm::I18n.t("tools.find_cases.title")
        description Bookworm::I18n.t("tools.find_cases.description")
        annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)
        input_schema(
          type: "object",
          properties: {
            query: Schemas.string(:query_cases),
            document_id: Schemas.string(:document_id_optional),
            anchor: Schemas.string(:anchor),
            limit: Schemas.integer(:limit_cases, minimum: 1, maximum: 100),
            include_text: Schemas.boolean(:include_case_text)
          }
        )
        output_schema(Schemas.find_cases_output)

        def self.call(server_context:, query: nil, document_id: nil, anchor: nil, limit: 20, include_text: true)
          Responder.call do
            Tools.app(server_context).find_cases(
              query: query,
              document_id: document_id,
              anchor: anchor,
              limit: limit,
              include_text: include_text
            )
          end
        end
      end

      class GetCaseTool < ::MCP::Tool
        tool_name "get_case"
        title Bookworm::I18n.t("tools.get_case.title")
        description Bookworm::I18n.t("tools.get_case.description")
        annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: false)
        input_schema(
          type: "object",
          properties: { case_id: Schemas.string(:case_id) },
          required: ["case_id"]
        )
        output_schema(Schemas.get_case_output)

        def self.call(case_id:, server_context:)
          Responder.call do
            Tools.app(server_context).get_case(case_id)
          end
        end
      end

      ALL = [
        IngestBookTool,
        IngestBooksTool,
        IngestTextTool,
        ListDocumentsTool,
        GetDocumentTool,
        GetOutlineTool,
        ReadPassageTool,
        ReadChapterTool,
        SearchTool,
        FindQuoteTool,
        DeleteDocumentTool,
        StatsTool,
        SearchEntitiesTool,
        GetEntityTool,
        GetRelationsTool,
        GetLogicalChainTool,
        FindCasesTool,
        GetCaseTool
      ].freeze
    end
  end
end
