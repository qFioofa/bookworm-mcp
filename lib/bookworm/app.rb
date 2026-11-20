# frozen_string_literal: true

require "digest"
require "set"
require "rgl/adjacency"
require "rgl/dijkstra"
require "rgl/dijkstra_visitor"

module Bookworm
  class App
    attr_reader :config, :store, :pipeline, :search_engine

    def initialize(config: Config.new)
      @config = config
      @store = Store::MemoryStore.new
      @pipeline = Ingest::Pipeline.new(store: @store, config: @config)
      @search_engine = Search::Engine.new(store: @store, config: @config)
      @graphs = {}
    end

    def ingest_book(path, title: nil)
      @pipeline.ingest_book(path, title: title)
    end

    def ingest_text(text, title: nil, format: "plain", language: nil, ttl_seconds: nil)
      @pipeline.ingest_text(
        text,
        title: title,
        format: format,
        language: language,
        ttl_seconds: ttl_seconds
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
      {
        document: document.to_h,
        outline: outline_node(document, document.root_node, depth: 2)
      }
    end

    def get_outline(document_id:, depth: 3, node_id: nil)
      document = fetch_document(document_id)
      root = node_id ? document.node(node_id.to_s) : document.root_node
      raise NotFoundError.new("Node not found", details: { document_id: document_id, node_id: node_id }) unless root

      depth = [[depth.to_i, 0].max, 10].min
      {
        document: document.to_h,
        root: outline_node(document, root, depth: depth)
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

      {
        passage: passage_payload(document, passage, limit),
        before: passages[[index - before, 0].max...index].to_a.map { |item| passage_payload(document, item, limit) },
        after: passages[(index + 1)..(index + after)].to_a.map { |item| passage_payload(document, item, limit) },
        document: document.to_h
      }
    end

    def find_quote(quote:, document_id: nil, fuzzy: false, max_results: 10)
      @store.remove_expired!
      query = quote.to_s.strip
      raise ValidationError.new("Quote must not be empty") if query.empty?

      documents = @store.documents
      if document_id
        document = fetch_document(document_id)
        documents = [document]
      end

      regex = quote_regex(query)
      occurrences = []

      documents.each do |document|
        document.passages.each do |passage|
          position = 0
          while (match = regex.match(passage.text, position))
            occurrences << quote_occurrence(
              document,
              passage,
              match[0],
              match.begin(0),
              match.end(0),
              match_type: passage.text.include?(query) ? "exact" : "normalized",
              similarity: 1.0,
              verified: true
            )
            position = match.begin(0) + [match[0].length, 1].max
          end
        end
      end

      if occurrences.empty? && fuzzy
        candidates = []
        documents.each do |document|
          document.passages.each do |passage|
            similarity = Search::Trigram.similarity(query, passage.text)
            next if similarity < 0.15

            candidates << { document: document, passage: passage, similarity: similarity }
          end
        end
        candidates.sort_by { |candidate| -candidate[:similarity] }.first(max_results.to_i).each do |candidate|
          occurrences << quote_occurrence(
            candidate[:document],
            candidate[:passage],
            nil,
            nil,
            nil,
            match_type: "fuzzy",
            similarity: candidate[:similarity],
            verified: false
          )
        end
      end

      occurrences = occurrences.sort_by do |occurrence|
        [
          occurrence[:citation][:document_id],
          occurrence[:citation][:start_char],
          occurrence[:span_start_char] || 0
        ]
      end

      limit = [[max_results.to_i, 1].max, @config.max_results].min
      {
        quote: query,
        total: occurrences.length,
        returned: [occurrences.length, limit].min,
        no_evidence: occurrences.empty?,
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
        graph.relations_for(entity.id).map { |relation| relation_payload(graph, relation, include_evidence: true) }
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
      include_url: false
    )
      format = normalize_format(format)
      graphs = scoped_graphs(document_id)
      depth = [[depth.to_i, 0].max, 5].min
      max_nodes = [[max_nodes.to_i, 1].max, 200].min
      limit = [[limit.to_i, 1].max, 500].min
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
      include_evidence: true, include_url: false
    )
      format = normalize_format(format)
      graphs = scoped_graphs(document_id)
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

      scores = {}
      if query && !query.to_s.strip.empty?
        result = search(
          query: query,
          document_id: document_id,
          k: [[limit.to_i * 4, 10].max, 50].min,
          include_text: false
        )
        result[:hits].each { |hit| scores[hit[:passage_id]] = hit[:score] }
      end

      items = []
      graphs.each do |graph|
        graph.cases.each do |item|
          next if anchor_entity && !item.linked_entity_ids.include?(anchor_entity.id)
          next if query && !scores.key?(item.passage_id)

          items << { graph: graph, case: item, score: scores[item.passage_id] || 0.0 }
        end
      end

      items.sort_by! do |item|
        [-item[:score], -item[:case].confidence.to_f, item[:case].citation[:start_char].to_i]
      end

      limit = [[limit.to_i, 1].max, 100].min
      {
        query: query,
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

        return {
          case: item.to_h(include_text: true),
          linked_entities: item.linked_entity_ids.filter_map { |id| graph.entity(id)&.to_h },
          document: graph.document.to_h
        }
      end

      raise NotFoundError.new("Case not found", details: { case_id: case_id })
    end

    def stats
      @store.remove_expired!
      @store.stats.merge(
        version: @store.version,
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

      direct = entity.normalized
      base = if direct == normalized
               100.0
             elsif direct.start_with?(normalized)
               70.0
             elsif direct.include?(normalized)
               50.0
             elsif normalized.split.all? { |token| direct.include?(token) }
               30.0
             else
               similarity = Search::Trigram.similarity(normalized, direct)
               return nil if similarity < 0.45

               20.0 * similarity
             end
      base + Math.log10(entity.mention_count + 1)
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
      exact = entities.find { |entity| entity.normalized == normalized }
      return exact if exact

      scored = entities.map do |entity|
        [entity, Search::Trigram.similarity(normalized, entity.normalized)]
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

    def passage_payload(document, passage, char_limit)
      text = passage.text
      truncated = false
      if char_limit && text.length > char_limit
        text = text[0...char_limit]
        truncated = true
      end

      {
        passage_id: passage.id,
        text: text,
        truncated: truncated,
        page: passage.page,
        chapter_path: passage.chapter_path,
        citation: Domain::Citation.build(document: document, passage: passage)
      }
    end

    def outline_node(document, node, depth:)
      payload = node.to_h.merge(
        passage_count: document.passage_count_for(node.id, include_descendants: true),
        direct_passage_count: document.passage_count_for(node.id, include_descendants: false)
      )
      if depth.positive?
        children = document.children_of(node.id).map do |child|
          outline_node(document, child, depth: depth - 1)
        end
        payload[:children] = children unless children.empty?
      end
      payload
    end

    def quote_regex(query)
      parts = query.split(/\s+/).map { |part| Regexp.escape(part) }
      Regexp.new(parts.join("\\s+"), Regexp::IGNORECASE)
    end

    def quote_occurrence(document, passage, matched_text, local_start, local_end, match_type:, similarity:, verified:)
      occurrence = {
        passage_id: passage.id,
        citation: Domain::Citation.build(document: document, passage: passage),
        local_start: local_start,
        local_end: local_end,
        span_start_char: local_start ? passage.start_char + local_start : nil,
        span_end_char: local_end ? passage.start_char + local_end : nil,
        matched_text: matched_text,
        match_type: match_type,
        similarity: similarity.round(4),
        verified: verified,
        quote_hash: matched_text ? Digest::SHA256.hexdigest(matched_text) : nil
      }
      occurrence
    end
  end
end
