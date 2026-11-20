# frozen_string_literal: true

require "time"

module Bookworm
  module Domain
    class Document
      attr_reader :id, :kind, :title, :authors, :language, :format,
                  :source_hash, :created_at, :expires_at, :nodes, :passages,
                  :metadata, :full_text

      def initialize(
        id:, kind:, title:, authors: [], language: "und", format: "text",
        source_hash:, created_at: Time.now, expires_at: nil, nodes: [],
        passages: [], metadata: {}, full_text: ""
      )
        @id = id
        @kind = kind
        @title = title
        @authors = authors
        @language = language
        @format = format
        @source_hash = source_hash
        @created_at = created_at
        @expires_at = expires_at
        @nodes = nodes
        @passages = passages
        @metadata = metadata
        @full_text = full_text
        @nodes_by_id = nodes.to_h { |node| [node.id, node] }
        @passages_by_id = passages.to_h { |passage| [passage.id, passage] }
      end

      def ephemeral?
        kind == "text" && !expires_at.nil?
      end

      def expired?(now = Time.now)
        !expires_at.nil? && expires_at <= now
      end

      def node(node_id)
        @nodes_by_id[node_id]
      end

      def passage(passage_id)
        @passages_by_id[passage_id]
      end

      def root_node
        nodes.find { |node| node.parent_id.nil? } || nodes.first
      end

      def children_of(node_id)
        nodes.select { |node| node.parent_id == node_id }.sort_by(&:ordinal)
      end

      def passage_count_for(node_id, include_descendants: true)
        return passages.count { |passage| passage.node_id == node_id } unless include_descendants

        ids = descendant_node_ids(node_id)
        passages.count { |passage| ids.include?(passage.node_id) }
      end

      def descendant_node_ids(node_id)
        result = [node_id]
        queue = [node_id]
        until queue.empty?
          current = queue.shift
          children_of(current).each do |child|
            result << child.id
            queue << child.id
          end
        end
        result
      end

      def to_h
        {
          document_id: id,
          kind: kind,
          title: title,
          authors: authors,
          language: language,
          format: format,
          source_hash: source_hash,
          ephemeral: ephemeral?,
          created_at: created_at.utc.iso8601,
          expires_at: expires_at&.utc&.iso8601,
          counts: {
            nodes: nodes.length,
            passages: passages.length,
            characters: full_text.length
          }
        }
      end
    end
  end
end
