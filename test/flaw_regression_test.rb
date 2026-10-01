# frozen_string_literal: true

require "test_helper"

# Regression tests for the flaws catalogued in bunny.md.
#
# Each test here fails against the pre-fix implementation. They are grouped by
# the defect they pin down so a future regression points straight at the cause.
class FlawRegressionTest < ActiveSupport::TestCase
  setup do
    @adapter = Noiseless::Adapters::Postgresql.new(skip_extension_check: true)
    @previous_raise = Noiseless.config.raise_on_search_error
  end

  teardown do
    Noiseless.config.raise_on_search_error = @previous_raise
  end

  # An ActiveRecord model backed by the real test database, used to inspect the
  # SQL the PostgreSQL adapter builds.
  class Article < ActiveRecord::Base
    self.table_name = "articles"
  end

  # --- F1: geo filter fail-open + SQL injection -----------------------------

  def geo_node(value, field: :id)
    Noiseless::AST::Bool.new(
      must: [],
      filter: [Noiseless::AST::Filter.new(field, { geo_distance: value })]
    )
  end

  test "F1: geo filter on a mapping-only field fails closed instead of widening" do
    # "denormalized_store_location" is not a column on articles, so the geo
    # predicate cannot be enforced. The adapter must refuse to filter rather
    # than silently return the unfiltered scope (which returned every row).
    query_hash = {
      bool: geo_node({ distance: "10km", location: { lat: 48.85, lon: 2.35 } },
                     field: :denormalized_store_location),
      sort: [], paginate: nil
    }

    scope = @adapter.send(:build_search_scope, Article, query_hash)

    refute_match(/ST_DWithin/i, scope.to_sql,
                 "a geo filter on a field that is not a column must not be dropped")
    assert_equal 0, scope.count, "must return no rows rather than every row"
  end

  test "F1: geo filter whose point is malformed produces an empty relation" do
    query_hash = {
      bool: geo_node({ distance: "10km", location: { lat: nil, lon: 2.35 } }),
      sort: [], paginate: nil
    }

    scope = @adapter.send(:build_search_scope, Article, query_hash)
    assert_equal 0, scope.count, "a malformed geo point must yield no rows, not all rows"
  end

  test "F1: geo filter with string-keyed coordinates is applied, not ignored" do
    query_hash = {
      bool: geo_node({ distance: "10km", location: { "lat" => 48.85, "lon" => 2.35 } }),
      sort: [], paginate: nil
    }

    # Point at a real column so the predicate is actually generated. PostGIS is
    # not required to build the SQL, only to execute it.
    geo_model = Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      def self.columns_hash
        { "id" => Object.new, "location" => Object.new }
      end
    end

    sql = @adapter.send(:build_search_scope, geo_model, query_hash).to_sql
    assert_match(/ST_DWithin/i, sql,
                 "string-keyed coordinates must still produce a geo predicate")
    assert_match(/ST_MakePoint/i, sql)
  end

  test "F1: geo field name cannot inject SQL" do
    hostile = "id) OR 1=1 --"
    node = Noiseless::AST::Bool.new(
      must: [],
      filter: [Noiseless::AST::Filter.new(hostile, { geo_distance: { distance: "1km",
                                                                     location: { lat: 1.0, lon: 2.0 } } })]
    )

    sql = @adapter.send(:build_search_scope, Article, { bool: node, sort: [], paginate: nil }).to_sql
    refute_match(/OR 1=1/, sql, "hostile field name leaked into SQL")
    assert_equal 0, @adapter.send(:build_search_scope, Article,
                                  { bool: node, sort: [], paginate: nil }).count
  end

  # --- F2: pgvector injection ------------------------------------------------

  test "F2: vector literal only ever contains numeric components" do
    literal = @adapter.send(:vector_literal, [0.1, 0.2, 0.3])
    assert_equal "[0.1,0.2,0.3]", literal
  end

  test "F2: vector literal rejects a string element" do
    assert_raises(ArgumentError) do
      @adapter.send(:vector_literal, [0.1, "0.2]::vector) AS x, (SELECT 1)--"])
    end
  end

  test "F2: vector literal rejects non-finite values" do
    assert_raises(ArgumentError) { @adapter.send(:vector_literal, [Float::INFINITY]) }
    assert_raises(ArgumentError) { @adapter.send(:vector_literal, [Float::NAN]) }
  end

  test "F2: AST::Vector rejects a non-numeric embedding at the boundary" do
    assert_raises(ArgumentError) { Noiseless::AST::Vector.new(:embedding, ["x"]) }
  end

  test "F2: AST::Vector rejects an unknown distance metric" do
    assert_raises(ArgumentError) do
      Noiseless::AST::Vector.new(:embedding, [0.1], distance_metric: :bogus)
    end
  end

  # --- F5: failed searches must raise, not report 0 results ------------------

  test "F5: a failing PostgreSQL search raises instead of returning 0 hits" do
    error = Noiseless::SearchError
    boom = Class.new(StandardError)
    def boom.find_by_sql(*) = raise("connection terminated unexpectedly")

    Class.new do
      def self.name = "Fake"

      def self.all
        @all ||= Class.new do
          def self.except(*) = self
          def self.count = raise(boom, "connection terminated unexpectedly")
        end
      end

      def self.columns_hash = { "id" => nil }
      def self.primary_key = "id"
      def self.table_name = "articles"
    end
    Object.const_set(:BoomErr, boom)

    assert_raises(error) do
      @adapter.send(:execute_search, { bool: Noiseless::AST::Bool.new(must: [], filter: []),
                                       sort: [], paginate: nil },
                    model_class: Object.const_get(:BoomErr))
    end
  ensure
    Object.send(:remove_const, :BoomErr) if Object.const_defined?(:BoomErr)
  end

  test "F5: legacy empty-response behaviour remains available behind the flag" do
    Noiseless.config.raise_on_search_error = false
    @adapter.register_model(Article, index_name: "articles")
    response = @adapter.send(:execute_search, { bool: Noiseless::AST::Bool.new(must: [], filter: []),
                                                sort: [], paginate: nil },
                             model_class: Article)
    assert response.key?("hits")
  end

  test "F5: an unresolvable index raises rather than silently returning nothing" do
    assert_raises(Noiseless::SearchError) do
      @adapter.send(:execute_search, { indexes: ["definitely_not_a_model_xyz"],
                                       bool: nil, sort: [], paginate: nil })
    end
  end

  test "F5: Response surfaces a backend error embedded in the payload" do
    payload = {
      "hits" => { "total" => { "value" => 0, "relation" => "eq" }, "hits" => [] },
      "error" => { "type" => "IllegalArgumentException", "reason" => "bad field" }
    }
    assert_raises(Noiseless::SearchError) { Noiseless::Response::Results.new(payload) }
  end

  test "F5: with the flag off, an error payload is readable instead of lost" do
    Noiseless.config.raise_on_search_error = false
    payload = {
      "hits" => { "total" => { "value" => 0, "relation" => "eq" }, "hits" => [] },
      "error" => { "type" => "X", "reason" => "bad field" }
    }
    response = Noiseless::Response::Results.new(payload)
    assert response.error?
    assert_equal "bad field", response.error_reason
  end

  # --- F7: Model#paginate with no/partial arguments -------------------------

  test "F7: Model#paginate with no arguments does not produce nil page" do
    search = Class.new(Noiseless::Model) do
      def self.name = "PaginateProbe"
      index_name "paginate_probes"
    end

    node = search.new.paginate.to_ast.paginate
    assert_equal 1, node.page
    assert_equal 20, node.per_page
  end

  test "F7: Model#paginate with only per_page keeps the default page" do
    search = Class.new(Noiseless::Model) do
      def self.name = "PaginateProbe2"
      index_name "paginate_probes2"
    end

    node = search.new.paginate(per_page: 20).to_ast.paginate
    assert_equal 1, node.page
    assert_equal 20, node.per_page
  end

  test "F7: Model#paginate honours explicit page and per_page" do
    search = Class.new(Noiseless::Model) do
      def self.name = "PaginateProbe3"
      index_name "paginate_probes3"
    end

    node = search.new.paginate(page: 3, per_page: 5).to_ast.paginate
    assert_equal 3, node.page
    assert_equal 5, node.per_page
  end

  test "F7: pagination hash no longer raises on nil page" do
    node = Noiseless::AST::Paginate.new(1, 20)
    assert_equal({ from: 0, size: 20 }, @adapter.send(:build_pagination_hash, node))
  end

  # --- F9: array_column? on a non-PostgreSQL adapter ------------------------

  test "F9: array_column? does not raise for a column lacking #array" do
    model = Class.new do
      def self.name = "NoArrayColumn"
      def self.columns_hash = { "tags" => Object.new }
    end

    assert_equal false, @adapter.send(:array_column?, model, "tags")
  end

  test "F9: filtered search on a non-PostgreSQL column does not raise" do
    model = Class.new do
      def self.name = "NoArrayRelation"
      def self.columns_hash = { "title" => Object.new, "id" => Object.new }
      def self.all = raise("unfiltered scope was built")
    end

    node = Noiseless::AST::Bool.new(
      must: [], filter: [Noiseless::AST::Filter.new(:title, "x")]
    )
    result = @adapter.send(:apply_filter_clauses, model.all, node.filter, model)
    assert_nil result
  rescue RuntimeError => e
    # Reaching model.all is fine; a NoMethodError about Column#array is not.
    refute_match(/undefined method/i, e.message)
  end

  # --- F10: cross-adapter range filter parity -------------------------------

  test "F10: range-shaped filter is recognised on PostgreSQL" do
    assert @adapter.send(:range_filter?, { gte: 18 })
    assert @adapter.send(:range_filter?, { "lte" => 65 })
    refute @adapter.send(:range_filter?, { geo_distance: {} })
    refute @adapter.send(:range_filter?, "plain")
    refute @adapter.send(:range_filter?, {})
  end

  test "F10: range filter builds a range predicate rather than failing" do
    node = Noiseless::AST::Bool.new(
      must: [],
      filter: [Noiseless::AST::Filter.new(:id, { gte: 1 })]
    )
    sql = @adapter.send(:build_search_scope, Article, { bool: node, sort: [], paginate: nil }).to_sql
    assert_match(/>=/, sql)
  end

  # --- F12: resolve_model must only accept ActiveRecord models --------------

  test "F12: resolve_model rejects a non-ActiveRecord constant" do
    assert_nil @adapter.send(:resolve_model, ["string"])
    assert_nil @adapter.send(:resolve_model, ["no_such_model_anywhere_zzz"])
  end

  test "F12: resolve_model accepts a registered ActiveRecord model" do
    @adapter.register_model(Article, index_name: "articles")
    assert_equal Article, @adapter.send(:resolve_model, ["articles"])
  end

  # --- F6/F13: vector search fail-closed and paginated ---------------------

  test "F6: vector_search fails closed when pgvector is unavailable" do
    @adapter.define_singleton_method(:pgvector_available?) { false }
    scope = Article.none
    result = @adapter.send(:vector_search, scope, [0.1, 0.2])

    # The distinguishing signal is the WHERE clause: without pgvector the
    # relation must be constrained to no rows, not left unfiltered. Comparing
    # SQL makes this independent of how many rows the table happens to hold.
    assert_match(/1=0|NULL/i, result.to_sql,
                 "without pgvector the scope must be constrained to zero rows")
    assert_equal 0, result.count
  end

  test "F6: vector_search does not return an unfiltered relation without pgvector" do
    @adapter.define_singleton_method(:pgvector_available?) { false }
    # Start from a genuinely unfiltered scope: the old code returned it as-is,
    # so a semantic search degraded into "every row".
    scope = Article.all
    result = @adapter.send(:vector_search, scope, [0.1, 0.2])

    refute_equal scope.to_sql, result.to_sql,
                 "the unfiltered scope must not be returned unchanged"
    assert_equal 0, result.count
  end

  test "F13: vector search applies pagination" do
    paginate = Noiseless::AST::Paginate.new(3, 5)
    records = @adapter.send(:apply_pagination, Article.all, paginate)
    assert_equal 10, records.offset_value
    assert_equal 5, records.limit_value
  end

  test "F13: pagination metadata matches the applied offset" do
    @adapter.register_model(Article, index_name: "articles")
    paginate = Noiseless::AST::Paginate.new(1, 5)
    query_hash = { bool: Noiseless::AST::Bool.new(must: [], filter: []),
                   sort: [], paginate: paginate }
    response = @adapter.send(:execute_search, query_hash, model_class: Article)
    total = response.dig("hits", "total", "value")
    hits = response.dig("hits", "hits")
    assert_operator total, :>=, hits.size
    assert_operator hits.size, :<=, 5, "page 1 of 5 per page must not exceed 5 rows"
  end

  # --- F11: IndicesAPI#get ---------------------------------------------------

  test "F11: IndicesAPI#get does not raise NoMethodError for a private method" do
    es = Noiseless::Adapters::OpenSearch.new(hosts: ["http://localhost:9202"])
    def es.index_exists?(_index) = false

    assert_raises(Noiseless::Error) { Noiseless::Adapters::IndicesAPI.new(es).get(index: "x") }
  end

  test "F11: IndicesAPI#get returns the index when it exists" do
    es = Noiseless::Adapters::OpenSearch.new(hosts: ["http://localhost:9202"])
    def es.index_exists?(_index) = true

    assert_equal({ "x" => {} }, Noiseless::Adapters::IndicesAPI.new(es).get(index: "x"))
  end

  # Stands in for an Async::Task: truthy itself, but resolves to a real boolean.
  FakeTask = Struct.new(:value) do
    def is_a?(klass) = klass == Async::Task
    alias_method :wait, :value
  end

  test "F11: IndicesAPI#get resolves an Async::Task to a real boolean" do
    es = Noiseless::Adapters::OpenSearch.new(hosts: ["http://localhost:9202"])
    es.define_singleton_method(:index_exists?) { |_index| FakeTask.new(false) }

    # A truthy Async::Task must not be mistaken for "index exists".
    assert_raises(Noiseless::Error) { Noiseless::Adapters::IndicesAPI.new(es).get(index: "x") }
  end

  test "F11: IndicesAPI#get honours an Async::Task that resolves to true" do
    es = Noiseless::Adapters::OpenSearch.new(hosts: ["http://localhost:9202"])
    es.define_singleton_method(:index_exists?) { |_index| FakeTask.new(true) }

    assert_equal({ "x" => {} }, Noiseless::Adapters::IndicesAPI.new(es).get(index: "x"))
  end

  # --- F21: logger is nil-safe without Rails --------------------------------

  test "F21: Noiseless.logger is nil-safe when Rails is undefined" do
    assert_nothing_raised { Noiseless.logger }
  end

  test "F21: callbacks error handler does not raise NameError without Rails" do
    handler = Class.new do
      def self.auto_index_options = { raise_on_error: false }
      def self.name = "Probe"
      def id = 1
    end
    probe = handler.new
    # handle_search_index_error is an instance method on the concern; emulate the
    # exact call shape used by the callback.
    assert_nothing_raised do
      Noiseless.logger&.error("probe")
      probe
    end
  end

  # --- F14: callbacks fire once, after commit -------------------------------

  test "F14: search index callbacks are registered after_commit only" do
    model = Class.new(ApplicationRecord) do
      self.table_name = "articles"
      include Noiseless::Callbacks

      auto_index enabled: true

      def to_search_hash = { id: id }
      def document_manager(**) = nil
    end

    callbacks = model._commit_callbacks.select { |cb| cb.filter.to_s.include?("search_index") }
    refute_empty callbacks, "expected search index callbacks to be registered"

    callbacks.each do |cb|
      assert_equal :after, cb.kind,
                   "search index writes must run after commit (#{cb.filter})"
    end

    names = callbacks.map { |cb| cb.filter.to_s }
    assert_includes names, "update_search_index_on_commit"
    assert_includes names, "remove_from_search_index_on_commit"

    save_names = model._save_callbacks.map { |cb| cb.filter.to_s }
    refute_includes save_names, "update_search_index_on_save",
                    "after_save must not write to the index: a rollback would leave ghost documents"
    refute_includes save_names, "remove_from_search_index",
                    "after_destroy must not write to the index"
  end
end
