# frozen_string_literal: true

module Noiseless
  class BulkImporter
    attr_reader :model_class, :errors

    def initialize(model_class, connection: nil)
      @model_class = model_class
      @connection = connection || model_class.connection
      @errors = []
    end

    def import(relation_or_records = nil,
               batch_size: 1000,
               transform: nil,
               preprocess: nil,
               force: false,
               refresh: true,
               **)
      @errors.clear

      # Recreate the index from scratch when force is true. The index must exist
      # before any document is written, otherwise the bulk calls below write
      # into a missing index.
      recreate_index! if force

      # Get records to import
      records = resolve_records(relation_or_records)

      total_imported = 0

      records.each_slice(batch_size) do |batch|
        # Apply preprocessing to the entire batch
        processed_batch = preprocess ? preprocess.call(batch) : batch

        # Transform individual records and build actions
        actions = build_bulk_actions(processed_batch, transform)

        # Execute bulk operation
        begin
          client = Noiseless.connections.client(@connection)
          response = client.bulk(actions, refresh: refresh, **)

          # Check for errors in response
          collect_errors(response, processed_batch)

          total_imported += actions.size
        rescue StandardError => e
          @errors << {
            error: e.message,
            batch: processed_batch.map { |r| identify_record(r) }
          }
        end
      end

      {
        imported: total_imported,
        errors: @errors.size,
        error_details: @errors
      }
    end

    def import_scoped(scope, **)
      import(scope, **)
    end

    def reindex(batch_size: 1000, **)
      raise ArgumentError, "Model class #{model_class} must respond to :all for reindexing" unless model_class.respond_to?(:all)

      import(model_class.all, batch_size: batch_size, force: true, **)
    end

    private

    def resolve_records(relation_or_records)
      case relation_or_records
      when nil
        model_class.respond_to?(:all) ? model_class.all : []
      when String, Symbol
        # Assume it's a scope name
        if model_class.respond_to?(relation_or_records)
          model_class.public_send(relation_or_records)
        else
          []
        end
      else
        relation_or_records
      end
    end

    def build_bulk_actions(batch, transform)
      batch.filter_map do |record|
        # Apply transform function if provided
        document = transform ? transform.call(record) : default_transform(record)
        next unless document

        {
          index: {
            _index: index_name,
            _id: extract_id(record),
            data: document
          }
        }
      rescue StandardError => e
        @errors << {
          error: e.message,
          record: identify_record(record)
        }
        nil
      end
    end

    def default_transform(record)
      if record.respond_to?(:to_h)
        record.to_h
      elsif record.respond_to?(:attributes)
        record.attributes
      else
        record
      end
    end

    def extract_id(record)
      if record.respond_to?(:id)
        record.id
      elsif record.is_a?(Hash)
        record[:id] || record["id"]
      else
        record.object_id
      end
    end

    def identify_record(record)
      id = extract_id(record)
      {
        id: id,
        class: record.class.name,
        object_id: record.object_id
      }
    end

    def collect_errors(response, batch)
      return unless response.is_a?(Hash) && response["items"]

      response["items"].each_with_index do |item, index|
        action = item.keys.first
        result = item[action]

        next unless result["error"]

        record = batch[index]
        @errors << {
          error: result["error"],
          record: identify_record(record),
          status: result["status"]
        }
      end
    end

    def index_name
      @index_name ||= if model_class.respond_to?(:search_index)
                        Array(model_class.search_index).first
                      else
                        model_class.name.demodulize.underscore.pluralize
                      end
    end

    def delete_index
      client = Noiseless.connections.client(@connection)
      client.delete_index(index_name).wait
      true
    rescue Noiseless::RequestError => e
      # A 404 means there was nothing to delete, which is the desired state.
      # Any other backend failure (auth, connectivity, timeout) is real and
      # must not be mistaken for "already absent".
      raise unless e.status == 404

      true
    end

    # Delete then recreate, aborting if the index cannot be restored. The
    # previous implementation called a create_index whose body was commented
    # out, so a forced reindex destroyed the index and then bulk-indexed into
    # a non-existent index — silent data loss.
    def recreate_index!
      delete_index
      return if create_index

      raise Noiseless::Error,
            "index #{index_name.inspect} was deleted but could not be recreated; " \
            "aborting import to avoid writing into a missing index"
    end

    # Create the index with the model's mapping. Returns true when the index
    # exists afterwards (created now, or already present).
    def create_index
      client = Noiseless.connections.client(@connection)

      return true if client.index_exists?(index_name).wait

      mappings = resolved_mapping
      if mappings.nil?
        # No mapping declared: create the index with default settings.
        client.create_index(index_name).wait
      else
        client.create_index(index_name, mappings: mappings).wait
      end

      true
    rescue StandardError => e
      @errors << { error: "Failed to create index: #{e.message}", index: index_name }
      false
    end

    # Convert the model's `mapping do ... end` block into the hash the adapters
    # expect, or nil when the model declares no mapping.
    def resolved_mapping
      return nil unless model_class.respond_to?(:mapping)

      mapping_block = model_class.mapping
      return nil unless mapping_block

      MappingDefinitionProcessor.process(mapping_block)
    end
  end
end
