# frozen_string_literal: true

module Noiseless
  class SearchIndexUpdateJob
    def self.perform_later(model_class_name, record_id, operation, options = {})
      if defined?(ActiveJob::Base)
        ActiveJobSearchIndexUpdateJob.perform_later(model_class_name, record_id, operation, options)
      elsif defined?(Sidekiq)
        SidekiqSearchIndexUpdateJob.perform_async(model_class_name, record_id, operation, options)
      else
        # Fallback to immediate execution
        perform_now(model_class_name, record_id, operation, options)
      end
    end

    def self.perform_now(model_class_name, record_id, operation, options = {})
      # safe_constantize: `constantize` on an arbitrary queued argument can load
      # any constant, and a bad name raised NameError that was then swallowed.
      model_class = model_class_name.safe_constantize
      raise Noiseless::Error, "Unknown model for indexing: #{model_class_name}" unless model_class

      case operation
      when "update"
        record = model_class.find(record_id)
        record.document_manager.update_document(**options)
      when "delete"
        # For delete operations, we need to construct a minimal object
        # since the record might already be deleted from the database
        document_manager = DocumentManager.new(
          DeletedRecord.new(model_class, record_id)
        )
        document_manager.delete_document(**options)
      else
        raise ArgumentError, "Unknown operation: #{operation}"
      end
    rescue StandardError => e
      # Re-raise when dispatched to a background queue so ActiveJob/Sidekiq
      # retry and dead-letter the job. perform_now previously swallowed the
      # error, so the job reported success on failure: no retry, no alert, and a
      # permanently broken index. Callers wanting the lenient behaviour can pass
      # raise_on_error: false.
      raise e if queue_backend? || options[:raise_on_error]

      Noiseless.logger&.error(
        "Noiseless: index #{operation} failed for #{model_class_name}##{record_id}: #{e.message}"
      )
      nil
    end

    # True when a background job backend is present, in which case failures must
    # propagate for retry/dead-letter semantics.
    def self.queue_backend?
      defined?(ActiveJob::Base) || defined?(Sidekiq)
    end

    # Minimal object for deleted records
    class DeletedRecord
      def initialize(model_class, record_id)
        @model_class = model_class
        @record_id = record_id
      end

      def id
        @record_id
      end

      def class
        @model_class
      end

      def to_search_document
        nil
      end
    end
  end

  # ActiveJob integration
  if defined?(ActiveJob::Base)
    class ActiveJobSearchIndexUpdateJob < ActiveJob::Base
      queue_as :default

      def perform(model_class_name, record_id, operation, options = {})
        SearchIndexUpdateJob.perform_now(model_class_name, record_id, operation, options)
      end
    end
  end

  # Sidekiq integration
  if defined?(Sidekiq)
    class SidekiqSearchIndexUpdateJob
      include Sidekiq::Worker

      def perform(model_class_name, record_id, operation, options = {})
        SearchIndexUpdateJob.perform_now(model_class_name, record_id, operation, options)
      end
    end
  end
end
