# frozen_string_literal: true

module Bookworm
  module Store
    class MemoryStore
      def initialize
        @documents = {}
        @by_source_hash = {}
        @mutex = Mutex.new
        @version = 0
      end

      def add(document)
        @mutex.synchronize do
          existing = @by_source_hash[document.source_hash]
          if existing
            return existing unless existing.expired?
            remove_unlocked(existing.id)
          end

          @documents[document.id] = document
          @by_source_hash[document.source_hash] = document
          @version += 1
          document
        end
      end

      def find_document(id)
        @mutex.synchronize { @documents[id] }
      end

      def find_by_source_hash(source_hash)
        @mutex.synchronize { @by_source_hash[source_hash] }
      end

      def documents
        @mutex.synchronize { @documents.values }
      end

      def find_passage(passage_id)
        @mutex.synchronize do
          @documents.each_value do |document|
            passage = document.passage(passage_id)
            return [document, passage] if passage
          end
        end
        nil
      end

      def remove(id)
        @mutex.synchronize { remove_unlocked(id) }
      end

      def remove_expired!
        now = Time.now
        @mutex.synchronize do
          @documents.values.select { |document| document.expired?(now) }.each do |document|
            remove_unlocked(document.id)
          end
        end
      end

      def version
        @mutex.synchronize { @version }
      end

      def stats
        @mutex.synchronize do
          {
            documents: @documents.length,
            passages: @documents.values.sum { |document| document.passages.length },
            characters: @documents.values.sum { |document| document.full_text.length }
          }
        end
      end

      private

      def remove_unlocked(id)
        document = @documents.delete(id)
        return unless document

        @by_source_hash.delete(document.source_hash) if @by_source_hash[document.source_hash]&.id == id
        @version += 1
        document
      end
    end
  end
end
