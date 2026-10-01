# frozen_string_literal: true

require "active_support/concern"

module Noiseless
  module Callbacks
    extend ActiveSupport::Concern

    included do
      # Index writes run only after commit. Previously both after_save and
      # after_commit triggered a write, so every save issued two HTTP
      # round-trips, and the after_save one ran before the transaction
      # committed — a rollback left documents in the search index that do not
      # exist in the database, with nothing to remove them.
      after_commit :update_search_index_on_commit, on: %i[create update]
      after_commit :remove_from_search_index_on_commit, on: :destroy
    end

    class_methods do
      def auto_index(enabled: true, **options)
        @auto_index_enabled = enabled
        @auto_index_options = options
      end

      def auto_index_enabled?
        @auto_index_enabled != false
      end

      def auto_index_options
        @auto_index_options ||= {}
      end

      def skip_auto_index
        previous_value = Thread.current[:noiseless_skip_auto_index]
        Thread.current[:noiseless_skip_auto_index] = true
        yield
      ensure
        Thread.current[:noiseless_skip_auto_index] = previous_value
      end
    end

    private

    def should_update_search_index?
      return false unless Noiseless.config.auto_index
      return false if Thread.current[:noiseless_skip_auto_index]
      return false unless self.class.auto_index_enabled?

      # Only update if we have searchable content
      if respond_to?(:searchable?)
        searchable?
      else
        true
      end
    end

    def update_search_index_on_commit
      return unless should_update_search_index?

      update_search_index_async
    rescue Noiseless::Error => e
      handle_search_index_error(e, :update)
    end

    def remove_from_search_index_on_commit
      return unless should_update_search_index?

      remove_from_search_index_async
    rescue Noiseless::Error => e
      handle_search_index_error(e, :delete)
    end

    def update_search_index_async
      options = self.class.auto_index_options

      if options[:async]
        # Queue for background processing
        SearchIndexUpdateJob.perform_later(
          self.class.name,
          id,
          "update",
          options
        )
      else
        # Immediate update
        document_manager.update_document(**options)
      end
    end

    def remove_from_search_index_async
      options = self.class.auto_index_options

      if options[:async]
        # Queue for background processing
        SearchIndexUpdateJob.perform_later(
          self.class.name,
          id,
          "delete",
          options
        )
      else
        # Immediate removal
        document_manager.delete_document(**options)
      end
    end

    def handle_search_index_error(error, operation)
      options = self.class.auto_index_options

      raise error if options[:raise_on_error]

      # Noiseless.logger is nil-safe: referencing Rails.logger here raised
      # NameError outside a Rails process, masking the original error.
      Noiseless.logger&.error(
        "Noiseless: Failed to #{operation} search index for #{self.class.name}##{id}: #{error.message}"
      )
    end

    def noiseless_new_record?
      if respond_to?(:persisted?)
        !persisted?
      else
        !id
      end
    end
  end
end
