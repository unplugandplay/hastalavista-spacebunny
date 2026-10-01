# frozen_string_literal: true

module Noiseless
  module AST
    # Vector search node for semantic/embedding-based search
    # Used with pgvector in PostgreSQL or knn in OpenSearch
    class Vector < Node
      attr_reader :field, :embedding, :k, :distance_metric

      DISTANCE_METRICS = %i[cosine l2 inner_product].freeze

      # @param field [Symbol, String] The embedding column/field
      # @param embedding [Array<Float>] The query embedding vector
      # @param k [Integer] Number of nearest neighbors (default: 10)
      # @param distance_metric [Symbol] :cosine, :l2, or :inner_product (default: :cosine)
      def initialize(field, embedding, k: 10, distance_metric: :cosine)
        super()
        @field = field
        @embedding = validate_embedding(embedding)
        @k = Integer(k)
        distance_metric = distance_metric.to_sym
        raise ArgumentError, "distance_metric must be one of #{DISTANCE_METRICS.join(', ')}" unless DISTANCE_METRICS.include?(distance_metric)

        @distance_metric = distance_metric
      end

      def dimension
        @embedding&.size || 0
      end

      private

      # Reject non-numeric and non-finite elements at the boundary. Adapters
      # interpolate the vector into a SQL literal, so a String element would
      # otherwise reach the query and allow SQL injection.
      #
      # A nil embedding is preserved (dimension then reports 0); it cannot
      # produce a vector query, and vector_literal raises if one is attempted.
      def validate_embedding(embedding)
        return nil if embedding.nil?

        values = Array(embedding)
        raise ArgumentError, "embedding must be a non-empty array of numbers" if values.empty?

        values.map do |value|
          float = Float(value)
          raise ArgumentError, "embedding contains a non-finite value" unless float.finite?

          float
        end
      rescue TypeError, ArgumentError => e
        raise ArgumentError, "embedding must contain only numbers (#{e.message})"
      end
    end
  end
end
