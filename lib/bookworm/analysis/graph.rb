# frozen_string_literal: true

require "set"
require "rgl/adjacency"
require "rgl/dijkstra"
require "rgl/dijkstra_visitor"

module Bookworm
  module Analysis
    class Graph
      attr_reader :document, :entities, :mentions, :relations, :cases

      def initialize(document:, entities:, mentions:, relations:, cases:)
        @document = document
        @entities = entities
        @mentions = mentions
        @relations = relations
        @cases = cases
        @mentions_by_entity = mentions.group_by(&:entity_id)
        @mentions_by_passage = mentions.group_by(&:passage_id)
      end

      def entity(entity_id)
        entities[entity_id]
      end

      def mentions_for(entity_id)
        @mentions_by_entity[entity_id] || []
      end

      def mentions_in_passage(passage_id)
        @mentions_by_passage[passage_id] || []
      end

      def cases_for(entity_id)
        cases.select { |item| item.linked_entity_ids.include?(entity_id) }
      end

      def relations_for(entity_id, predicates: nil)
        selected = relations.select do |relation|
          relation.source_id == entity_id || relation.target_id == entity_id
        end
        return selected unless predicates && !predicates.empty?

        allowed = predicates.map(&:upcase)
        selected.select { |relation| allowed.include?(relation.predicate) }
      end

      def adjacency
        @adjacency ||= begin
          map = Hash.new { |hash, key| hash[key] = Set.new }
          entities.each_key { |entity_id| map[entity_id] }
          relations.each do |relation|
            map[relation.source_id] << relation.target_id
            map[relation.target_id] << relation.source_id unless relation.directed
          end
          map
        end
      end

      def neighborhood(entity_id, depth: 1)
        depth = [depth.to_i, 0].max
        visited = Set.new([entity_id])
        frontier = [entity_id]
        depth.times do
          next_frontier = []
          frontier.each do |current|
            adjacency[current].each do |neighbor|
              next if visited.include?(neighbor)

              visited << neighbor
              next_frontier << neighbor
            end
          end
          frontier = next_frontier
          break if frontier.empty?
        end
        visited.to_a
      end

      def to_rgl
        graph = RGL::DirectedAdjacencyGraph.new
        entities.each_key { |entity_id| graph.add_vertex(entity_id) }
        relations.each do |relation|
          graph.add_edge(relation.source_id, relation.target_id)
          graph.add_edge(relation.target_id, relation.source_id) unless relation.directed
        end
        graph
      end

      def shortest_path(source_id, target_id)
        graph = to_rgl
        return nil unless graph.has_vertex?(source_id) && graph.has_vertex?(target_id)

        weights = {}
        graph.each_edge { |source, target| weights[[source, target]] = 1.0 }
        visitor = RGL::DijkstraVisitor.new(graph)
        RGL::DijkstraAlgorithm.new(graph, weights, visitor).shortest_path(source_id, target_id)
      end

      def best_relation(source_id, target_id)
        candidates = relations.select do |relation|
          (relation.source_id == source_id && relation.target_id == target_id) ||
            (!relation.directed && relation.source_id == target_id && relation.target_id == source_id)
        end
        candidates.max_by { |relation| [relation.confidence.to_f, relation.count.to_i] }
      end
    end
  end
end
