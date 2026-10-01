# frozen_string_literal: true

module Noiseless
  module Adapters
    # Indices API - needed for index management operations
    class IndicesAPI
      def initialize(adapter)
        @adapter = adapter
      end

      def get(index:)
        # index_exists? returns an Async::Task, which is always truthy — calling
        # the private execute_index_exists? raised NoMethodError, and awaiting
        # the task without inspecting it would always report "exists". Resolve
        # the task to a real boolean.
        exists = @adapter.index_exists?(index)
        exists = exists.wait if exists.is_a?(Async::Task)
        raise Noiseless::Error, "Index not found: #{index}" unless exists

        { index => {} }
      end

      def stats(index:)
        # Return basic stats structure
        { "indices" => { index => {} } }
      end

      def refresh(index:)
        # Refresh the index to make documents immediately searchable
        @adapter.refresh_index(index).wait
      end
    end
  end
end
