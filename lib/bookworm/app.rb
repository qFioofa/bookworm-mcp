# frozen_string_literal: true

require "digest"
require "set"
require "rgl/adjacency"
require "rgl/dijkstra"
require "rgl/dijkstra_visitor"

module Bookworm
  class App
    DEFAULT_MIN_CONFIDENCE = 0.5

    attr_reader :config, :store, :pipeline, :search_engine

    def initialize(config: Config.new)
      @config = config
      @store = Store::MemoryStore.new
      @pipeline = Ingest::Pipeline.new(store: @store, config: @config)
      @search_engine = Search::Engine.new(store: @store, config: @config)
      @graphs = {}
    end

    def ingest_book(path, title: nil, replace: false)
      @pipeline.ingest_book(path, title: title, replace: replace).document
    end

    def ingest_book_result(path, title: nil, replace: false)
      @pipeline.ingest_book(path, title: title, replace: replace)
    end

    def ingest_books(paths, title: nil, replace: false)
      results = Array(paths).map do |path|
        result = @pipeline.ingest_book(path, title: title, replace: replace)
        {
          path: path.to_s,
          document: result.document.to_h,
          cached: result.cached,
          first_passage_id: result.document.passages.first&.id
        }
      rescue Bookworm::Error => e
        {
          path: path.to_s,
          error: { code: e.code, message: e.message, details: e.details }
        }
      end

      {
        total: results.length,
        succeeded: results.count { |item| !item.key?(:error) },
        failed: results.count { |item| item.key?(:error) },
        results: results
      }
    end

    def ingest_text(text = nil, title: nil, format: nil, language: nil, ttl_seconds: nil, source_path: nil, source_url: nil)
      @pipeline.ingest_text(
        text,
        title: title,
        format: format,
        language: language,
        ttl_seconds: ttl_seconds,
        source_path: source_path,
        source_url: source_url
      ).document
    end

    def ingest_text_result(text = nil, title: nil, format: nil, language: nil, ttl_seconds: nil, source_path: nil, source_url: nil)
      @pipeline.ingest_text(
        text,
        title: title,
        format: format,
        language: language,
        ttl_seconds: ttl_seconds,
        source_path: source_path,
        source_url: source_url
      )
    end

    def search(**args)
      @search_engine.search(**args)
    end

    def list_documents(kind: nil, limit: 100)
      @store.remove_expired!
      documents = @store.documents
      documents = documents.select { |document| document.kind == kind.to_s } if kind
      documents = documents.sort_by(&:created_at).reverse
      limit = [[limit.to_i, 1].max, 500].min
      {
        total: documents.length,
        documents: documents.first(limit).map(&:to_h)
      }
    end

    def get_document(document_id)
      document = fetch_document(document_id)
      built = build_outline(document, document.root_node, depth: 1, max_nodes: 50, titles_only: true)
      {
        document: document.to_h,
        outline: built[:root]
      }
    end

    def get_outline(document_id:, depth: 10, node_id: nil, max_nodes: 200, titles_only: false)
      document = fetch_document(document_id)
      root = node_id ? document.node(node_id.to_s) : document.root_node
      raise NotFoundError.new("Node not found", details: { document_id: document_id, node_id: node_id }) unless root

      depth = [[depth.to_i, 0].max, 10].min
      max_nodes = max_nodes.nil? ? 200 : [[max_nodes.to_i, 1].max, 1000].min
      built = build_outline(document, root, depth: depth, max_nodes: max_nodes, titles_only: titles_only)
      {
        document: document.to_h,
        root: built[:root],
        returned_nodes: built[:returned_nodes],
        truncated: built[:truncated]
      }
    end

    def read_passage(passage_id:, before: 1, after: 1, max_tokens: nil)
      @store.remove_expired!
      found = @store.find_passage(passage_id.to_s)
      raise NotFoundError.new("Passage not found", details: { passage_id: passage_id }) unless found

      document, passage = found
      passages = document.passages.sort_by(&:ordinal)
      index = passages.index { |item| item.id == passage.id } || 0
      before = [[before.to_i, 0].max, 20].min
      after = [[after.to_i, 0].max, 20].min
      limit = max_tokens ? max_tokens.to_i * 4 : nil

      before_passages = passages[[index - before, 0].max...index].to_a
      after_passages = passages[(index + 1)..(index + after)].to_a
      returned = [passage] + before_passages + after_passages
      {
        passage: passage_payload(document, passage, limit, include_footnotes: true),
        before: before_passages.map { |item| passage_payload(document, item, limit, include_footnotes: true) },
        after: after_passages.map { |item| passage_payload(document, item, limit, include_footnotes: true) },
        footnotes: footnotes_payload(document, returned),
        document: document.to_h
      }
    end

    def read_chapter(document_id:, node_id:, offset: 0, limit: 50, max_tokens: nil, include_footnotes: true)
      document = fetch_document(document_id)
      node = document.node(node_id.to_s)
      raise NotFoundError.new("Node not found", details: { document_id: document_id, node_id: node_id }) unless node

      passages = document.passages_for(node.id, include_descendants: true)
      offset = [[offset.to_i, 0].max, passages.length].min
      limit = [[limit.to_i, 1].max, 200].min
      slice = passages[offset, limit] || []
      char_limit = max_tokens ? max_tokens.to_i * 4 : nil
      range = document.content_range(node.id)

      {
        document: document.to_h,
        node: build_outline(document, node, depth: 0, max_nodes: 1, titles_only: false)[:root],
        passages: slice.map do |passage|
          passage_payload(document, passage, char_limit, include_footnotes: include_footnotes)
        end,
        footnotes: include_footnotes ? footnotes_payload(document, slice) : [],
        offset: offset,
        total: passages.length,
        returned: slice.length,
        next_offset: offset + slice.length < passages.length ? offset + slice.length : nil,
        range: range ? { start_char: range[0], end_char: range[1] } : nil
      }
    end

    def find_quote(quote:, document_id: nil, fuzzy: false, max_results: 10, source: "any")
      @store.remove_expired!
      query = quote.to_s.strip
      raise ValidationError.new("Quote must not be empty") if query.empty?

      source = normalize_quote_source(source)
      documents = @store.documents
      if document_id
        document = fetch_document(document_id)
        documents = [document]
      end
      documents = documents.select { |document| quote_source_matches?(document, source) }

      occurrences = documents.flat_map { |document| document_quote_occurrences(document, query) }

      if occurrences.empty? && fuzzy
        occurrences = fuzzy_quote_occurrences(documents, query, max_results)
      end

      occurrences = sort_quote_occurrences(occurrences)
      limit = [[max_results.to_i, 1].max, @config.max_results].min
      book_evidence = occurrences.count do |item|
        %w[book footnote].include?(item.dig(:verification, :source))
      end
      text_evidence = occurrences.count { |item| item.dig(:verification, :source) == "text" }
      {
        quote: query,
        source: source,
        total: occurrences.length,
        returned: [occurrences.length, limit].min,
        no_evidence: occurrences.empty?,
        book_evidence: book_evidence,
        text_evidence: text_evidence,
        occurrences: occurrences.first(limit)
      }
    end

    def remove_document(document_id)
      document = @pipeline.remove(document_id)
      @graphs.delete(document.id)
      document
    end

    def search_entities(query: nil, document_id: nil, type: nil, limit: 20)
      graphs = scoped_graphs(document_id)
      normalized = normalize_entity_query(query)
      entries = {}

      graphs.each do |graph|
        graph.entities.each_value do |entity|
          next if type && entity.type != type.to_s

          score = entity_score(entity, normalized)
          next if score.nil?

          entry = entries[entity.id] ||= {
            entity_id: entity.id,
            name: entity.name,
            type: entity.type,
            aliases: [],
            mention_count: 0,
            document_ids: [],
            score: score
          }
          entry[:aliases] |= entity.aliases
          entry[:mention_count] += entity.mention_count
          entry[:document_ids] |= entity.document_ids
          entry[:score] = [entry[:score], score].max
        end
      end

      limit = [[limit.to_i, 1].max, 100].min
      sorted = entries.values.sort_by do |entry|
        [-entry[:score], -entry[:mention_count], entry[:name].to_s.downcase]
      end

      {
        query: query,
        total: sorted.length,
        returned: [sorted.length, limit].min,
        entities: sorted.first(limit).map do |entry|
          entry.merge(
            document_count: entry[:document_ids].length,
            score: entry[:score].round(3)
          )
        end
      }
    end

    def get_entity(entity_id)
      graphs = all_graphs
      found = graphs.filter_map do |graph|
        entity = graph.entity(entity_id.to_s)
        [graph, entity] if entity
      end
      raise NotFoundError.new("Entity not found", details: { entity_id: entity_id }) if found.empty?

      entity = found.map(&:last).max_by(&:mention_count)
      mention_count = found.sum { |graph, _entity| graph.mentions_for(entity.id).length }
      document_ids = found.flat_map { |_graph, item| item.document_ids }.uniq

      mentions = found.flat_map do |graph, _entity|
        graph.mentions_for(entity.id).filter_map { |mention| mention_payload(graph.document, mention) }
      end.first(50)

      relations = found.flat_map do |graph, _entity|
        graph.relations_for(entity.id)
             .select { |relation| relation.confidence.to_f >= DEFAULT_MIN_CONFIDENCE }
             .map { |relation| relation_payload(graph, relation, include_evidence: true) }
      end.first(100)

      cases = found.flat_map do |graph, _entity|
        graph.cases_for(entity.id).map { |item| item.to_h(include_text: false) }
      end.first(20)

      {
        entity: entity.to_h.merge(
          mention_count: mention_count,
          document_count: document_ids.length,
          document_ids: document_ids
        ),
        mentions: mentions,
        relations: relations,
        cases: cases
      }
    end

    def get_relations(
      entity_id: nil, document_id: nil, depth: 1, predicates: nil,
      limit: 100, format: "json", include_evidence: true, max_nodes: 50,
      include_url: false, min_confidence: DEFAULT_MIN_CONFIDENCE
    )
      format = normalize_format(format)
      graphs = scoped_graphs(document_id)
      depth = [[depth.to_i, 0].max, 5].min
      max_nodes = [[max_nodes.to_i, 1].max, 200].min
      limit = [[limit.to_i, 1].max, 500].min
      min_confidence = normalize_confidence(min_confidence)
      allowed_predicates = normalize_predicates(predicates)
      nodes = {}
      edges = {}

      if entity_id
        entity_id = entity_id.to_s
        matching = graphs.select { |graph| graph.entity(entity_id) }
        raise NotFoundError.new("Entity not found", details: { entity_id: entity_id }) if matching.empty?

        matching.each do |graph|
          graph.neighborhood(entity_id, depth: depth).each do |id|
            add_graph_node(nodes, graph, id)
          end
          graph.relations.each do |relation|
            next unless nodes.key?(relation.source_id) && nodes.key?(relation.target_id)
            next if relation.confidence.to_f < min_confidence
            next if allowed_predicates && !allowed_predicates.include?(relation.predicate)

            add_graph_edge(edges, graph, relation, include_evidence: include_evidence)
          end
        end
      else
        graphs.each do |graph|
          graph.entities.each_key do |id|
            break if nodes.length >= max_nodes * 2

            add_graph_node(nodes, graph, id)
          end
          graph.relations.each do |relation|
            next if relation.confidence.to_f < min_confidence
            next if allowed_predicates && !allowed_predicates.include?(relation.predicate)

            add_graph_edge(edges, graph, relation, include_evidence: include_evidence)
          end
        end
      end

      total_nodes = nodes.length
      total_edges = edges.length
      nodes = nodes.values.first(max_nodes)
      node_ids = nodes.to_h { |node| [node[:entity_id], true] }
      edges = edges.values.select do |edge|
        node_ids[edge[:source_id]] && node_ids[edge[:target_id]]
      end.first(limit)

      payload = {
        entity_id: entity_id,
        document_id: document_id,
        depth: depth,
        min_confidence: min_confidence,
        total_nodes: total_nodes,
        total_edges: total_edges,
        nodes: nodes,
        edges: edges,
        truncated: total_nodes > nodes.length || total_edges > edges.length
      }
      attach_plantuml!(payload, format, include_url: include_url, include_evidence: include_evidence)
      payload
    end

    def get_logical_chain(
      start:, finish:, document_id: nil, max_depth: 4, format: "json",
      include_evidence: true, include_url: false, min_confidence: DEFAULT_MIN_CONFIDENCE
    )
      format = normalize_format(format)
      graphs = scoped_graphs(document_id)
      min_confidence = normalize_confidence(min_confidence)
      start_entity = resolve_entity(start, graphs)
      finish_entity = resolve_entity(finish, graphs)
      unless start_entity && finish_entity
        raise NotFoundError.new(
          "Entity not found",
          details: { start: start, finish: finish, start_found: !start_entity.nil?, finish_found: !finish_entity.nil? }
        )
      end

      graph = RGL::DirectedAdjacencyGraph.new
      nodes = {}
      edge_map = {}

      graphs.each do |item|
        item.entities.each_value do |entity|
          add_graph_node(nodes, item, entity.id)
          graph.add_vertex(entity.id)
        end
        item.relations.each do |relation|
          next if relation.confidence.to_f < min_confidence

          graph.add_edge(relation.source_id, relation.target_id)
          graph.add_edge(relation.target_id, relation.source_id) unless relation.directed
          remember_edge(edge_map, relation, item)
          remember_edge(edge_map, reverse_relation(relation), item) unless relation.directed
        end
      end

      path = if graph.has_vertex?(start_entity.id) && graph.has_vertex?(finish_entity.id)
               weights = {}
               graph.each_edge { |source, target| weights[[source, target]] = 1.0 }
               visitor = RGL::DijkstraVisitor.new(graph)
               RGL::DijkstraAlgorithm.new(graph, weights, visitor).shortest_path(start_entity.id, finish_entity.id)
             end

      chain_nodes = path.to_a.filter_map { |id| nodes[id] }
      chain_edges = path.to_a.each_cons(2).filter_map do |source_id, target_id|
        entry = edge_map[[source_id, target_id]]
        next unless entry

        relation_payload(entry[:graph], entry[:relation], include_evidence: include_evidence)
      end

      completeness = if path.nil?
                       "not_found"
                     elsif path.length - 1 <= [[max_depth.to_i, 1].max, 10].min
                       "complete"
                     else
                       "partial"
                     end

      payload = {
        start: start_entity.to_h,
        finish: finish_entity.to_h,
        path: path.to_a,
        hops: path ? path.length - 1 : nil,
        min_confidence: min_confidence,
        completeness: completeness,
        nodes: chain_nodes,
        edges: chain_edges
      }
      attach_plantuml!(payload, format, include_url: include_url, include_evidence: include_evidence)
      payload
    end

    def find_cases(query: nil, document_id: nil, anchor: nil, limit: 20, include_text: true)
      graphs = scoped_graphs(document_id)
      anchor_entity = anchor ? resolve_entity(anchor, graphs) : nil
      if anchor && !anchor_entity
        raise NotFoundError.new("Entity not found", details: { anchor: anchor })
      end

      query = query.to_s.strip
      items = []
      graphs.each do |graph|
        graph.cases.each do |item|
          next if anchor_entity && !item.linked_entity_ids.include?(anchor_entity.id)

          score = query.empty? ? 0.0 : case_score(item, query)
          next if !query.empty? && score <= 0.0

          items << { graph: graph, case: item, score: score }
        end
      end

      items.sort_by! do |item|
        [-item[:score], -item[:case].confidence.to_f, item[:case].start_char.to_i]
      end

      limit = [[limit.to_i, 1].max, 100].min
      {
        query: query.empty? ? nil : query,
        anchor: anchor,
        total: items.length,
        returned: [items.length, limit].min,
        cases: items.first(limit).map do |item|
          payload = item[:case].to_h(include_text: include_text)
          payload[:score] = item[:score].round(3)
          payload[:linked_entities] = item[:case].linked_entity_ids.filter_map do |id|
            item[:graph].entity(id)&.name
          end
          payload
        end
      }
    end

    def get_case(case_id)
      all_graphs.each do |graph|
        item = graph.cases.find { |candidate| candidate.id == case_id.to_s }
        next unless item

        passages = Array(item.passage_ids).filter_map do |passage_id|
          passage = graph.document.passage(passage_id)
          next unless passage

          {
            passage_id: passage.id,
            text: passage.text,
            citation: Domain::Citation.build(document: graph.document, passage: passage)
          }
        end

        return {
          case: item.to_h(include_text: true),
          passages: passages,
          linked_entities: item.linked_entity_ids.filter_map { |id| graph.entity(id)&.to_h },
          document: graph.document.to_h
        }
      end

      raise NotFoundError.new("Case not found", details: { case_id: case_id })
    end

    def stats(document_id: nil)
      @store.remove_expired!
      if document_id
        document = fetch_document(document_id)
        return {
          documents: 1,
          passages: document.passages.length,
          characters: document.full_text.length,
          version: @store.version,
          cache: @pipeline.cache_stats,
          document: document.to_h,
          config: {
            max_inline_bytes: @config.max_inline_bytes,
            default_ttl: @config.default_ttl,
            max_passage_chars: @config.max_passage_chars
          }
        }
      end

      @store.stats.merge(
        version: @store.version,
        cache: @pipeline.cache_stats,
        config: {
          max_inline_bytes: @config.max_inline_bytes,
          default_ttl: @config.default_ttl,
          max_passage_chars: @config.max_passage_chars
        }
      )
    end

    private

    def all_graphs
      @store.remove_expired!
      @store.documents.map { |document| graph_for(document) }
    end

    def scoped_graphs(document_id)
      return all_graphs if document_id.nil?

      [graph_for(fetch_document(document_id))]
    end

    def graph_for(document)
      @graphs[document.id] ||= Analysis::Extractor.new(document).call
    end

    def normalize_entity_query(query)
      query.to_s.downcase.tr("ё", "е")
           .gsub(/[^\p{L}\p{N}\s\-]/u, " ")
           .gsub(/\s+/, " ")
           .strip
    end

    def entity_score(entity, normalized)
      return 1.0 + Math.log10(entity.mention_count + 1) if normalized.empty?

      scores = entity_names(entity).filter_map do |direct|
        entity_name_score(direct, normalized)
      end
      return nil if scores.empty?

      scores.max + Math.log10(entity.mention_count + 1)
    end

    def entity_names(entity)
      ([entity.normalized] + Array(entity.aliases).map { |alias_name| normalize_entity_query(alias_name) }).uniq
    end

    def entity_name_score(direct, normalized)
      return 100.0 if direct == normalized
      return 70.0 if direct.start_with?(normalized)
      return 50.0 if direct.include?(normalized)
      return 30.0 if normalized.split.all? { |token| direct.include?(token) }

      similarity = Search::Trigram.similarity(normalized, direct)
      similarity < 0.45 ? nil : 20.0 * similarity
    end

    def case_score(item, query)
      normalized_query = Util::Text.normalize_for_match(query)
      terms = Search::Tokenizer.terms(query).uniq
      text = Util::Text.normalize_for_match(item.text)
      stems = Search::Tokenizer.terms(item.text).to_set
      matched = terms.count { |term| stems.include?(term) }
      coverage = terms.empty? ? 0.0 : matched.to_f / terms.length
      phrase = normalized_query.empty? || !text.include?(normalized_query) ? 0.0 : 1.0
      score = (coverage * 0.8) + (phrase * 0.6)
      return score if score.positive? || normalized_query.empty?

      similarity = Search::Trigram.similarity(normalized_query, text)
      similarity >= 0.35 ? similarity : 0.0
    end

    def mention_payload(document, mention)
      passage = document.passage(mention.passage_id)
      return nil unless passage

      {
        passage_id: mention.passage_id,
        surface: mention.surface,
        start_char: mention.start_char,
        end_char: mention.end_char,
        citation: Domain::Citation.build(document: document, passage: passage)
      }
    end

    def relation_payload(graph, relation, include_evidence:)
      relation.to_h(include_evidence: include_evidence).merge(
        source_name: graph.entity(relation.source_id)&.name,
        target_name: graph.entity(relation.target_id)&.name,
        document_id: graph.document.id
      )
    end

    def normalize_format(format)
      value = (format || "json").to_s
      return value if %w[json plantuml both].include?(value)

      raise ValidationError.new(
        "Unknown format: #{value}",
        details: { supported: %w[json plantuml both] }
      )
    end

    def normalize_predicates(predicates)
      return nil if predicates.nil?

      list = predicates.is_a?(Array) ? predicates : predicates.to_s.split(",")
      list = list.map { |predicate| predicate.to_s.strip.upcase }.reject(&:empty?).uniq
      list.empty? ? nil : list
    end

    def normalize_confidence(value)
      number = value.nil? ? DEFAULT_MIN_CONFIDENCE : value.to_f
      [[number, 0.0].max, 1.0].min
    end

    def add_graph_node(nodes, graph, entity_id)
      entity = graph.entity(entity_id)
      return unless entity

      node = nodes[entity_id] ||= {
        entity_id: entity.id,
        name: entity.name,
        type: entity.type,
        aliases: [],
        mention_count: 0,
        document_ids: []
      }
      node[:aliases] |= entity.aliases
      node[:mention_count] += entity.mention_count
      node[:document_ids] |= entity.document_ids
    end

    def add_graph_edge(edges, graph, relation, include_evidence:)
      source_id, target_id = if relation.directed
                               [relation.source_id, relation.target_id]
                             else
                               [relation.source_id, relation.target_id].sort
                             end
      key = [source_id, target_id, relation.predicate]
      existing = edges[key]

      if existing
        existing[:count] += relation.count
        existing[:confidence] = [existing[:confidence], relation.confidence].max
        if include_evidence
          existing[:evidence] = (existing[:evidence] + relation.evidence).first(3)
        end
      else
        edges[key] = {
          relation_id: relation.id,
          source_id: source_id,
          target_id: target_id,
          predicate: relation.predicate,
          directed: relation.directed,
          count: relation.count,
          confidence: relation.confidence,
          method: relation.method,
          document_id: graph.document.id,
          evidence: include_evidence ? relation.evidence.first(3) : []
        }
      end
    end

    def remember_edge(map, relation, graph)
      key = [relation.source_id, relation.target_id]
      existing = map[key]
      if existing.nil? || [relation.confidence.to_f, relation.count.to_i] > [existing[:relation].confidence.to_f, existing[:relation].count.to_i]
        map[key] = { relation: relation, graph: graph }
      end
    end

    def reverse_relation(relation)
      Analysis::Relation.new(
        id: relation.id,
        source_id: relation.target_id,
        target_id: relation.source_id,
        predicate: relation.predicate,
        directed: relation.directed,
        count: relation.count,
        confidence: relation.confidence,
        method: relation.method,
        evidence: relation.evidence
      )
    end

    def resolve_entity(value, graphs)
      needle = value.to_s
      entities = graphs.flat_map { |graph| graph.entities.values }.uniq(&:id)
      direct = entities.find { |entity| entity.id == needle }
      return direct if direct

      normalized = normalize_entity_query(needle)
      exact = entities.find { |entity| entity_names(entity).include?(normalized) }
      return exact if exact

      scored = entities.map do |entity|
        similarity = entity_names(entity).map do |name|
          Search::Trigram.similarity(normalized, name)
        end.max || 0.0
        [entity, similarity]
      end.max_by { |entity, similarity| [similarity, entity.mention_count] }
      return scored.first if scored && scored.last >= 0.6

      nil
    end

    def attach_plantuml!(payload, format, include_url:, include_evidence:)
      return unless %w[plantuml both].include?(format)

      source = Analysis::Plantuml.render(
        nodes: payload[:nodes],
        edges: payload[:edges],
        title: Bookworm::I18n.t("graph.title"),
        include_evidence: include_evidence
      )
      payload[:plantuml] = source
      payload[:plantuml_url] = Analysis::Plantuml.url(source) if include_url
    end

    def fetch_document(document_id)
      @store.remove_expired!
      document = @store.find_document(document_id.to_s)
      raise NotFoundError.new("Document not found", details: { document_id: document_id }) unless document

      document
    end

    def passage_payload(document, passage, char_limit, include_footnotes: false)
      text = passage.text
      truncated = false
      if char_limit && text.length > char_limit
        text = text[0...char_limit]
        truncated = true
      end

      payload = {
        passage_id: passage.id,
        text: text,
        truncated: truncated,
        page: passage.page,
        chapter_path: passage.chapter_path,
        citation: Domain::Citation.build(document: document, passage: passage)
      }
      if include_footnotes
        payload[:footnote_ids] = passage.footnote_ids
        payload[:footnotes] = footnotes_payload(document, [passage])
      end
      payload
    end

    def footnotes_payload(document, passages)
      passages.flat_map(&:footnote_ids).uniq.filter_map do |footnote_id|
        document.footnote(footnote_id)&.to_h
      end
    end

    def build_outline(document, node, depth:, max_nodes:, titles_only:)
      budget = { count: 0, truncated: false }
      root = outline_node(
        document,
        node,
        depth: depth,
        max_nodes: max_nodes,
        titles_only: titles_only,
        budget: budget
      )
      { root: root, returned_nodes: budget[:count], truncated: budget[:truncated] }
    end

    def outline_node(document, node, depth:, max_nodes:, titles_only:, budget:)
      if budget[:count] >= max_nodes
        budget[:truncated] = true
        return nil
      end

      budget[:count] += 1
      payload = if titles_only
                  node.to_h.slice(:node_id, :parent_id, :kind, :title, :level, :page_start, :page_end)
                else
                  range = document.content_range(node.id)
                  first_passage = document.first_passage_for(node.id)
                  last_passage = document.last_passage_for(node.id)
                  node.to_h.merge(
                    passage_count: document.passage_count_for(node.id, include_descendants: true),
                    direct_passage_count: document.passage_count_for(node.id, include_descendants: false),
                    content_start_char: range&.first,
                    content_end_char: range&.last,
                    first_passage_id: first_passage&.id,
                    last_passage_id: last_passage&.id,
                    footnote_count: document.footnote_ids_for(node.id).length
                  )
                end

      if depth.positive?
        children = []
        document.children_of(node.id).each do |child|
          built = outline_node(
            document,
            child,
            depth: depth - 1,
            max_nodes: max_nodes,
            titles_only: titles_only,
            budget: budget
          )
          unless built
            budget[:truncated] = true
            break
          end
          children << built
        end
        payload[:children] = children unless children.empty?
      end

      payload
    end

    def quote_regex(query)
      parts = query.split(/\s+/).map { |part| Regexp.escape(part) }
      Regexp.new(parts.join("\\s+"), Regexp::IGNORECASE)
    end

    def normalize_quote_source(source)
      value = (source || "any").to_s
      return value if %w[any book text].include?(value)

      raise ValidationError.new(
        "Unknown quote source: #{value}",
        details: { supported: %w[any book text] }
      )
    end

    def quote_source_matches?(document, source)
      return true if source == "any"

      document.kind == source
    end

    def document_quote_occurrences(document, query)
      occurrences = []
      regex = quote_regex(query)
      passages = document.passages.sort_by(&:start_char)

      scan_text_occurrences(document.full_text, regex) do |matched, start_char, end_char|
        overlapping = overlapping_passages(passages, start_char, end_char)
        citation = quote_citation(document, start_char, end_char, matched, overlapping.first)
        match_type = document.full_text[start_char...end_char] == query ? "exact" : "normalized"
        occurrences << text_quote_occurrence(
          document,
          matched,
          start_char,
          end_char,
          citation,
          overlapping,
          match_type
        )
      end

      document.footnotes.each do |footnote|
        scan_text_occurrences(footnote.text, regex) do |matched, start_char, end_char|
          match_type = footnote.text[start_char...end_char] == query ? "exact" : "normalized"
          occurrences << footnote_quote_occurrence(
            document,
            footnote,
            matched,
            start_char,
            end_char,
            match_type
          )
        end
      end

      occurrences
    end

    def scan_text_occurrences(text, regex)
      position = 0
      while (match = regex.match(text, position))
        yield match[0], match.begin(0), match.end(0)
        position = match.begin(0) + [match[0].length, 1].max
      end
    end

    def overlapping_passages(passages, start_char, end_char)
      index = passages.bsearch_index { |passage| passage.end_char > start_char }
      return [] unless index

      result = []
      while index < passages.length
        passage = passages[index]
        break if passage.start_char >= end_char

        result << passage if passage.end_char > start_char
        index += 1
      end
      result
    end

    def quote_citation(document, start_char, end_char, matched_text, passage)
      return Domain::Citation.build(document: document, passage: passage) if passage

      node = document.nodes.find do |item|
        item.start_char && item.end_char && item.start_char < end_char && item.end_char > start_char
      end
      Domain::Citation.build_span(
        document: document,
        start_char: start_char,
        end_char: end_char,
        text: matched_text,
        node_id: node&.id,
        chapter_path: node ? [node.title].compact : []
      )
    end

    def text_quote_occurrence(document, matched_text, start_char, end_char, citation, overlapping, match_type)
      source = document.kind == "book" ? "book" : "text"
      occurrence = {
        passage_id: overlapping.first&.id,
        passage_ids: overlapping.map(&:id),
        footnote_id: nil,
        label: nil,
        location: "text",
        citation: citation,
        local_start: local_quote_offset(overlapping.first, start_char),
        local_end: local_quote_end(overlapping.first, end_char),
        span_start_char: start_char,
        span_end_char: end_char,
        matched_text: matched_text,
        match_type: match_type,
        similarity: 1.0,
        verified: true,
        quote_hash: Digest::SHA256.hexdigest(matched_text),
        verification: verification_payload(
          document,
          source: source,
          span: [start_char, end_char],
          passage_ids: overlapping.map(&:id),
          exact: match_type == "exact"
        )
      }
      occurrence[:warning] = Bookworm::I18n.t("quotes.text_warning") if source == "text"
      occurrence
    end

    def local_quote_offset(passage, start_char)
      return nil unless passage
      return nil if start_char < passage.start_char || start_char >= passage.end_char

      start_char - passage.start_char
    end

    def local_quote_end(passage, end_char)
      return nil unless passage
      return nil if end_char > passage.end_char

      end_char - passage.start_char
    end

    def footnote_quote_occurrence(document, footnote, matched_text, start_char, end_char, match_type)
      {
        passage_id: nil,
        passage_ids: [],
        footnote_id: footnote.id,
        label: footnote.label,
        location: "footnote",
        citation: Domain::Citation.build_for_footnote(
          document: document,
          footnote: footnote,
          start_char: start_char,
          end_char: end_char,
          text: matched_text
        ),
        local_start: start_char,
        local_end: end_char,
        span_start_char: nil,
        span_end_char: nil,
        matched_text: matched_text,
        match_type: match_type,
        similarity: 1.0,
        verified: true,
        quote_hash: Digest::SHA256.hexdigest(matched_text),
        verification: verification_payload(
          document,
          source: "footnote",
          span: nil,
          passage_ids: [],
          exact: match_type == "exact",
          footnote_id: footnote.id
        )
      }
    end

    def fuzzy_quote_occurrences(documents, query, max_results)
      candidates = []
      documents.each do |document|
        document.passages.each do |passage|
          similarity = Search::Trigram.similarity(query, passage.text)
          next if similarity < 0.15

          candidates << { document: document, passage: passage, similarity: similarity }
        end
      end

      candidates.sort_by { |candidate| -candidate[:similarity] }.first(max_results.to_i).map do |candidate|
        document = candidate[:document]
        passage = candidate[:passage]
        source = document.kind == "book" ? "book" : "text"
        occurrence = {
          passage_id: passage.id,
          passage_ids: [passage.id],
          footnote_id: nil,
          label: nil,
          location: "text",
          citation: Domain::Citation.build(document: document, passage: passage),
          local_start: nil,
          local_end: nil,
          span_start_char: nil,
          span_end_char: nil,
          matched_text: nil,
          match_type: "fuzzy",
          similarity: candidate[:similarity].round(4),
          verified: false,
          quote_hash: nil,
          verification: verification_payload(
            document,
            source: source,
            span: nil,
            passage_ids: [passage.id],
            exact: false
          )
        }
        occurrence[:warning] = Bookworm::I18n.t("quotes.text_warning") if source == "text"
        occurrence
      end
    end

    def verification_payload(document, source:, span:, passage_ids:, exact:, footnote_id: nil)
      {
        source: source,
        document_id: document.id,
        document_kind: document.kind,
        document_title: document.title,
        ephemeral: document.ephemeral?,
        exact: exact,
        span: span ? { start_char: span[0], end_char: span[1] } : nil,
        passage_ids: passage_ids,
        footnote_id: footnote_id
      }
    end

    def sort_quote_occurrences(occurrences)
      rank = { "book" => 0, "footnote" => 1, "text" => 2 }
      occurrences.sort_by do |occurrence|
        [
          rank[occurrence.dig(:verification, :source)].to_i,
          occurrence[:citation][:document_id].to_s,
          occurrence[:span_start_char] || occurrence[:local_start] || 0
        ]
      end
    end
  end
end
