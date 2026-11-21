# frozen_string_literal: true

module Bookworm
  module MCP
    module Schemas
      module_function

      def object(properties, required = [])
        { type: "object", properties: properties, required: required }
      end

      def array(items)
        { type: "array", items: items }
      end

      def description(value)
        return nil if value.nil?
        return value if value.is_a?(String)

        Bookworm::I18n.t("schemas.#{value}", default: value.to_s)
      end

      def string(description_key = nil)
        result = { type: "string" }
        text = description(description_key)
        result[:description] = text if text
        result
      end

      def integer(description_key = nil, minimum: nil, maximum: nil)
        result = { type: "integer" }
        text = description(description_key)
        result[:description] = text if text
        result[:minimum] = minimum if minimum
        result[:maximum] = maximum if maximum
        result
      end

      def number(description_key = nil)
        result = { type: "number" }
        text = description(description_key)
        result[:description] = text if text
        result
      end

      def boolean(description_key = nil)
        result = { type: "boolean" }
        text = description(description_key)
        result[:description] = text if text
        result
      end

      def citation
        object(
          {
            document_id: string,
            document_kind: string,
            document_title: string,
            passage_id: { type: ["string", "null"] },
            node_id: { type: ["string", "null"] },
            chapter_path: array(string),
            page: { type: ["integer", "null"] },
            paragraph_index: integer,
            start_char: integer,
            end_char: integer,
            quote_hash: string,
            verified: boolean,
            footnote_id: { type: ["string", "null"] },
            footnote_label: { type: ["string", "null"] }
          },
          %w[document_id passage_id start_char end_char verified]
        )
      end

      def document_summary
        object(
          {
            document_id: string,
            kind: string,
            title: string,
            authors: array(string),
            language: string,
            format: string,
            source_hash: string,
            ephemeral: boolean,
            created_at: string,
            expires_at: { type: ["string", "null"] },
            counts: object(
              {
                nodes: integer,
                passages: integer,
                footnotes: integer,
                characters: integer
              },
              %w[nodes passages characters]
            )
          },
          %w[document_id kind title counts]
        )
      end

      def footnote
        object(
          {
            footnote_id: string,
            label: string,
            node_id: { type: ["string", "null"] },
            text: string
          },
          %w[footnote_id label]
        )
      end

      def passage_payload
        object(
          {
            passage_id: string,
            text: string,
            truncated: boolean,
            page: { type: ["integer", "null"] },
            chapter_path: array(string),
            citation: citation,
            footnote_ids: array(string),
            footnotes: array(footnote)
          },
          %w[passage_id text citation]
        )
      end

      def highlight
        object({ start: integer, end: integer, term: string }, %w[start end term])
      end

      def search_hit
        object(
          {
            rank: integer,
            passage_id: string,
            citation: citation,
            snippet: string,
            highlights: array(highlight),
            score: number,
            raw_score: number,
            score_breakdown: object(
              {
                lexical: number,
                vector: number,
                phrase: number,
                title: number,
                exact: number,
                fuzzy: number,
                fused: number
              }
            ),
            matched_terms: array(string),
            coverage: number,
            match_type: string,
            entity_ids: array(string),
            text: string,
            text_truncated: boolean
          },
          %w[rank passage_id citation snippet score match_type]
        )
      end

      def search_output
        object(
          {
            query: string,
            mode: string,
            retrieval: string,
            semantic: boolean,
            fallback: { type: ["string", "null"] },
            verbosity: string,
            total: integer,
            returned: integer,
            limit: integer,
            next_cursor: { type: ["string", "null"] },
            hits: array(search_hit),
            took_ms: number
          },
          %w[query mode total returned hits took_ms]
        )
      end

      def outline_node
        {
          type: "object",
          properties: {
            node_id: string,
            parent_id: { type: ["string", "null"] },
            kind: string,
            title: { type: ["string", "null"] },
            level: integer,
            page_start: { type: ["integer", "null"] },
            page_end: { type: ["integer", "null"] },
            start_char: { type: ["integer", "null"] },
            end_char: { type: ["integer", "null"] },
            content_start_char: { type: ["integer", "null"] },
            content_end_char: { type: ["integer", "null"] },
            first_passage_id: { type: ["string", "null"] },
            last_passage_id: { type: ["string", "null"] },
            footnote_count: integer,
            passage_count: integer,
            direct_passage_count: integer,
            children: array({ type: "object" })
          }
        }
      end

      def document_output
        object(
          {
            document: document_summary,
            outline: outline_node
          },
          %w[document outline]
        )
      end

      def ingest_output
        object(
          {
            document: document_summary,
            cached: boolean,
            first_passage_id: { type: ["string", "null"] }
          },
          %w[document]
        )
      end

      def ingest_books_output
        object(
          {
            total: integer,
            succeeded: integer,
            failed: integer,
            results: array(object({
              path: string,
              document: document_summary,
              cached: boolean,
              first_passage_id: { type: ["string", "null"] },
              error: { type: "object" }
            }))
          },
          %w[total succeeded failed results]
        )
      end

      def read_passage_output
        object(
          {
            passage: passage_payload,
            before: array(passage_payload),
            after: array(passage_payload),
            footnotes: array(footnote),
            document: document_summary
          },
          %w[passage before after document]
        )
      end

      def read_chapter_output
        object(
          {
            document: document_summary,
            node: outline_node,
            passages: array(passage_payload),
            footnotes: array(footnote),
            offset: integer,
            total: integer,
            returned: integer,
            next_offset: { type: ["integer", "null"] },
            range: {
              type: ["object", "null"],
              properties: {
                start_char: integer,
                end_char: integer
              }
            }
          },
          %w[document node passages footnotes total returned]
        )
      end

      def quote_occurrence
        object(
          {
            passage_id: { type: ["string", "null"] },
            passage_ids: array(string),
            footnote_id: { type: ["string", "null"] },
            label: { type: ["string", "null"] },
            location: string,
            citation: citation,
            local_start: { type: ["integer", "null"] },
            local_end: { type: ["integer", "null"] },
            span_start_char: { type: ["integer", "null"] },
            span_end_char: { type: ["integer", "null"] },
            matched_text: { type: ["string", "null"] },
            match_type: string,
            similarity: number,
            verified: boolean,
            quote_hash: { type: ["string", "null"] },
            verification: { type: "object" },
            warning: string
          },
          %w[passage_id passage_ids citation match_type similarity verified verification]
        )
      end

      def find_quote_output
        object(
          {
            quote: string,
            source: string,
            total: integer,
            returned: integer,
            no_evidence: boolean,
            book_evidence: integer,
            text_evidence: integer,
            occurrences: array(quote_occurrence)
          },
          %w[quote source total returned no_evidence occurrences]
        )
      end

      def outline_output
        object(
          {
            document: document_summary,
            root: outline_node,
            returned_nodes: integer,
            truncated: boolean
          },
          %w[document root returned_nodes truncated]
        )
      end

      def list_documents_output
        object({ total: integer, documents: array(document_summary) }, %w[total documents])
      end

      def stats_output
        object(
          {
            documents: integer,
            passages: integer,
            characters: integer,
            version: integer,
            cache: object({ hits: integer, misses: integer }),
            document: document_summary,
            locale: string,
            config: object({
              max_inline_bytes: integer,
              default_ttl: integer,
              max_passage_chars: integer
            })
          },
          %w[documents passages characters version]
        )
      end
      def entity_summary
        object(
          {
            entity_id: string,
            name: string,
            type: string,
            aliases: array(string),
            mention_count: integer,
            document_count: integer,
            document_ids: array(string),
            score: number
          },
          %w[entity_id name type mention_count]
        )
      end

      def relation_edge
        object(
          {
            relation_id: string,
            source_id: string,
            target_id: string,
            source_name: { type: ["string", "null"] },
            target_name: { type: ["string", "null"] },
            predicate: string,
            directed: boolean,
            count: integer,
            confidence: number,
            method: string,
            document_id: string,
            evidence: array({ type: "object" })
          },
          %w[relation_id source_id target_id predicate directed confidence]
        )
      end

      def mention_summary
        object(
          {
            passage_id: string,
            surface: string,
            start_char: integer,
            end_char: integer,
            citation: citation
          },
          %w[passage_id surface citation]
        )
      end

      def search_entities_output
        object(
          {
            query: { type: ["string", "null"] },
            total: integer,
            returned: integer,
            entities: array(entity_summary)
          },
          %w[total returned entities]
        )
      end

      def get_entity_output
        object(
          {
            entity: entity_summary,
            mentions: array(mention_summary),
            relations: array(relation_edge),
            cases: array({ type: "object" })
          },
          %w[entity mentions relations cases]
        )
      end

      def graph_output
        object(
          {
            entity_id: { type: ["string", "null"] },
            document_id: { type: ["string", "null"] },
            depth: integer,
            min_confidence: number,
            total_nodes: integer,
            total_edges: integer,
            nodes: array(entity_summary),
            edges: array(relation_edge),
            truncated: boolean,
            plantuml: string,
            plantuml_url: string
          },
          %w[nodes edges truncated]
        )
      end

      def logical_chain_output
        object(
          {
            start: entity_summary,
            finish: entity_summary,
            path: array(string),
            hops: { type: ["integer", "null"] },
            min_confidence: number,
            completeness: string,
            nodes: array(entity_summary),
            edges: array(relation_edge),
            plantuml: string,
            plantuml_url: string
          },
          %w[start finish path completeness nodes edges]
        )
      end

      def case_summary
        object(
          {
            case_id: string,
            document_id: string,
            passage_id: string,
            passage_ids: array(string),
            node_id: string,
            chapter_path: array(string),
            title: string,
            kind: string,
            kind_label: string,
            markers: array(string),
            citation: citation,
            range: object({ start_char: integer, end_char: integer }),
            linked_entity_ids: array(string),
            linked_entities: array(string),
            confidence: number,
            method: string,
            score: number,
            text: string
          },
          %w[case_id document_id passage_id passage_ids title kind citation]
        )
      end

      def find_cases_output
        object(
          {
            query: { type: ["string", "null"] },
            anchor: { type: ["string", "null"] },
            total: integer,
            returned: integer,
            cases: array(case_summary)
          },
          %w[total returned cases]
        )
      end

      def get_case_output
        object(
          {
            case: case_summary,
            passages: array(object({
              passage_id: string,
              text: string,
              citation: citation
            })),
            linked_entities: array(entity_summary),
            document: document_summary
          },
          %w[case passages linked_entities document]
        )
      end

    end
  end
end
