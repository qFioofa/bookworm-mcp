# frozen_string_literal: true

require "time"

module Bookworm
  module Domain
    class Document
      attr_reader :id, :kind, :title, :authors, :language, :format,
                  :source_hash, :created_at, :expires_at, :nodes, :passages,
                  :metadata, :full_text, :footnotes

      def initialize(
        id:, kind:, title:, authors: [], language: "und", format: "text",
        source_hash:, created_at: Time.now, expires_at: nil, nodes: [],
        passages: [], metadata: {}, full_text: "", footnotes: []
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
        @footnotes = Array(footnotes)
        @nodes_by_id = nodes.to_h { |node| [node.id, node] }
        @passages_by_id = passages.to_h { |passage| [passage.id, passage] }
        @footnotes_by_id = @footnotes.to_h { |footnote| [footnote.id, footnote] }
        @passages_by_node = passages.group_by(&:node_id)
        @children_by_parent = nodes.group_by(&:parent_id)
        @content_ranges = build_content_ranges
        @node_counts, @node_first_passages, @node_last_passages, @node_footnote_ids = build_node_aggregates
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
        (@children_by_parent[node_id] || []).sort_by(&:ordinal)
      end

      def passage_count_for(node_id, include_descendants: true)
        return (@passages_by_node[node_id] || []).length unless include_descendants

        @node_counts[node_id] || 0
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

      def direct_passages_for(node_id)
        (@passages_by_node[node_id] || []).sort_by(&:ordinal)
      end

      def passages_for(node_id, include_descendants: true)
        return direct_passages_for(node_id) unless include_descendants

        ids = descendant_node_ids(node_id)
        passages.select { |passage| ids.include?(passage.node_id) }.sort_by(&:ordinal)
      end

      def content_range(node_id)
        @content_ranges[node_id]
      end

      def first_passage_for(node_id, include_descendants: true)
        return direct_passages_for(node_id).first unless include_descendants

        @node_first_passages[node_id]
      end

      def last_passage_for(node_id, include_descendants: true)
        return direct_passages_for(node_id).last unless include_descendants

        @node_last_passages[node_id]
      end

      def footnote(footnote_id)
        @footnotes_by_id[footnote_id]
      end

      def footnotes_for(ids)
        Array(ids).filter_map { |footnote_id| footnote(footnote_id) }
      end

      def footnote_ids_for(node_id, include_descendants: true)
        return @node_footnote_ids[node_id] || [] if include_descendants

        direct_passages_for(node_id).flat_map(&:footnote_ids).uniq
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
            footnotes: footnotes.length,
            characters: full_text.length
          }
        }
      end

      private

      def build_content_ranges
        ranges = {}
        @passages_by_node.each do |node_id, node_passages|
          ranges[node_id] = [
            node_passages.map(&:start_char).min,
            node_passages.map(&:end_char).max
          ]
        end

        merge = lambda do |node|
          range = ranges[node.id]
          children_of(node.id).each do |child|
            range = merge_range(range, merge.call(child))
          end
          ranges[node.id] = range
          range
        end

        root = root_node
        merge.call(root) if root
        ranges
      end

      def merge_range(left, right)
        return right if left.nil?
        return left if right.nil?

        [[left[0], right[0]].min, [left[1], right[1]].max]
      end

      def build_node_aggregates
        counts = Hash.new(0)
        firsts = {}
        lasts = {}
        footnotes = Hash.new { |hash, key| hash[key] = [] }

        @passages_by_node.each do |node_id, node_passages|
          ordered = node_passages.sort_by(&:ordinal)
          counts[node_id] = ordered.length
          firsts[node_id] = ordered.first
          lasts[node_id] = ordered.last
          footnotes[node_id] = ordered.flat_map(&:footnote_ids).uniq
        end

        merge = lambda do |node|
          children_of(node.id).each do |child|
            merge.call(child)
            counts[node.id] += counts[child.id]
            child_first = firsts[child.id]
            if child_first && (!firsts[node.id] || child_first.ordinal < firsts[node.id].ordinal)
              firsts[node.id] = child_first
            end
            child_last = lasts[child.id]
            if child_last && (!lasts[node.id] || child_last.ordinal > lasts[node.id].ordinal)
              lasts[node.id] = child_last
            end
            footnotes[node.id] = (footnotes[node.id] + footnotes[child.id]).uniq
          end
        end

        root = root_node
        merge.call(root) if root
        [counts, firsts, lasts, footnotes]
      end
    end
  end
end
