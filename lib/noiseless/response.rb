# frozen_string_literal: true

module Noiseless
  module Response
    class Base
      include Enumerable
      include Pagination::ResponsePagination

      # Extract a human-readable reason from the various error shapes backends
      # use ({ type:, reason: }, { error: "..." }, or a bare string).
      def error_reason(err = error)
        case err
        when Hash
          err["reason"] || err["message"] || err["type"] || err.to_s
        when String
          err
        else
          err.to_s
        end
      end

      # True when the backend reported a failure inside an otherwise
      # well-formed search-response envelope.
      def error
        @raw_response["error"]
      end

      def error?
        !error.nil?
      end

      def initialize(raw_response, model_class = nil)
        @raw_response = raw_response
        @model_class = model_class

        # Adapters embed backend failures in the response body while still
        # returning a valid hits envelope. Without this check a failed query
        # is indistinguishable from an empty result set: total == 0,
        # empty? == true, and no exception anywhere.
        return unless error? && Noiseless.config.raise_on_search_error

        raise Noiseless::SearchError, "search failed: #{error_reason(error)}"
      end

      def total
        case @raw_response.dig("hits", "total")
        when Hash
          @raw_response.dig("hits", "total", "value") || 0
        when Integer
          @raw_response.dig("hits", "total") || 0
        else
          0
        end
      end

      def hits
        @hits ||= @raw_response.dig("hits", "hits") || []
      end

      def took
        @raw_response["took"]
      end

      def aggregations
        @aggregations ||= Aggregations.new(@raw_response["aggregations"] || {})
      end

      def suggestions
        @suggestions ||= Suggestions.new(@raw_response["suggest"] || {})
      end

      def each(&)
        raise NotImplementedError, "Subclasses must implement #each"
      end

      def empty?
        total.zero?
      end

      delegate :size, to: :hits

      def length
        size
      end

      def include_pagination_info(query_hash)
        @from = query_hash[:from] || 0
        @per_page = query_hash[:size] || 20
      end

      # Compatibility methods for CommonShare
      def response
        @raw_response
      end

      def result
        # Alias for results - controllers expect .result
        results
      end

      def results
        # For Results class, return self. For Records, return a Results view
        if is_a?(Results)
          self
        else
          Results.new(@raw_response, @model_class)
        end
      end

      def count
        size
      end

      def total_count
        total
      end

      def each_with_index(&)
        return enum_for(__method__) unless block_given?

        each.with_index(&)
      end

      private

      attr_reader :raw_response, :model_class
    end
  end
end
