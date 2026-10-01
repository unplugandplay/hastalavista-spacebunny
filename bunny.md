# Noiseless — Code Audit & Enhancement Proposal

> **Status: Tier 1–3 fixed in this change; see [`DEVLOG.md`](DEVLOG.md).**
> 35 regression tests added in `test/flaw_regression_test.rb`, each labelled with the
> flaw number below. Tier 4 (hygiene) partially addressed: `Rails.logger` is now
> nil-safe everywhere via `Noiseless.logger`, `mapping.rb` uses `YAML.safe_load`, and
> the duplicate bind in `hybrid_search` is removed. Remaining Tier 4 items and
> follow-ups are listed at the bottom of the DevLog.
>
> Items **F15, F16, F17, F18, F19, F20, F23, F24, F25, F27, F28** are still open —
> see "Notes / follow-ups" in the DevLog.

Audit of `noiseless` v0.7.2 (69 files / 7,692 LOC in `lib`, 28 test files).
Every claim below is line-referenced to the pre-fix code. Items marked **[verified]**
were reproduced by executing the code, not merely read.

## Executive summary

The gem's **stated core promise** is "runtime validation" and safe multi-backend
abstraction (README:7). The audit found the promise is only partly kept:

| Area | State |
|---|---|
| Elasticsearch / OpenSearch error handling | **Correct** — failures raise |
| PostgreSQL / Typesense error handling | **Broken** — failures become "0 results" |
| SQL construction (PostgreSQL) | Mostly good `quoted_column` + bind params, with 3 exceptions |
| Field/value validation in DSL | **Absent entirely** (`grep -rn "def validate" lib/` → no hits) |
| Test coverage of the risky paths | Gaps mirror exactly the bugs found |

The single most damaging theme: **on 2 of 4 backends, a crashed query is
indistinguishable from an empty result set.** In production this presents as
"search is broken, but the dashboard says zero results, no alerts, no logs."

---

## Tier 1 — Security & data-loss defects

### F1. SQL injection + **fail-open** geo filter (PostgreSQL)
`lib/noiseless/adapters/execution_modules/postgresql_execution.rb:293-313`

```ruby
293: def apply_geo_filter(scope, node)
300:   geo_point = geo_config.find { |_k, v| v.is_a?(Hash) && v[:lat] && v[:lon] }&.last
301:   return scope unless geo_point          # <-- returns UNFILTERED scope
305:     "ST_DWithin(#{field}::geography, ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography, ?)",
310: rescue StandardError
312:   scope                                    # <-- returns UNFILTERED scope
```

Two independent defects on the same 20 lines:

1. **Injection.** `field` is interpolated raw at :305. Every other clause builder
   uses `quoted_column(field)` (:197, :204, :220, :242, :248, :261, :290, :325) **and**
   an `column?` allow-list (:191, :237, :246, :259, :272). Geo is the only one missing both.
   A field name of `title) OR 1=1 --` breaks out of the predicate.
2. **Fail-open.** If the point is missing, has string keys, or `lat`/`lon` is nil,
   line 301 returns the *unfiltered* scope. **[verified]** — the predicate vanishes
   from the SQL entirely; "articles near Paris" returns every published row worldwide.
   This directly contradicts the fail-closed discipline applied everywhere else in the
   same file (commit `0c06698` "fail-closed clauses").

There is **zero geo test coverage** (`grep -rn geo test/postgresql*.rb` → no hits).

### F2. pgvector embedding interpolated as a raw SQL literal
`pgvector_support.rb:31,37,43,49` and `:142,146-149`

```ruby
 31: vector_string = "[#{embedding.join(',')}]"
 37:   "#{quoted_column(column)} #{distance_op} '#{vector_string}' AS vector_distance"
 49: scope.order(Arel.sql("#{quoted_column(column)} #{distance_op} '#{vector_string}'"))
```
`AST::Vector#initialize` (`ast/vector.rb:14-19`) performs **no type coercion**, so a
string element reaches the SQL literal and breaks out into both the SELECT list and
the ORDER BY. `batch_store_embeddings` (:141-152) is worse: fully hand-built SQL,
unquoted `#{column}` and `#{model.table_name}`, and a hardcoded `v.id::uuid` that
raises on any non-UUID primary key.

### F3. `reindex` deletes the index and never recreates it → data loss
`lib/noiseless/bulk_importer.rb:177-193`

```ruby
183: begin
184:   _client = Noiseless.connections.client(@connection)
185:   # This would need to be implemented in the adapter
186:   # client.create_index(index_name, mapping: mapping_block)
```
`create_index` is a **stub**: the only statement is an assignment to an unused local;
the real call is commented out. Since `reindex` (:68-72) and `import(force: true)`
(:23-26) call `delete_index` then `create_index`, both destroy the index and then bulk
index into a non-existent one. Per-document errors accumulate in `@errors` but callers
typically only check "did it raise".

### F4. `refresh:` is accepted by the public API and silently dropped
`bulk_importer.rb:18,43` → `adapter.rb:51-57,89-110` → `es_compatible_execution.rb:16`

```ruby
# es_compatible_execution.rb
16: def execute_bulk(actions, **_opts)      # opts swallowed
27:   response = post_request("/_bulk", body, ...)   # no ?refresh=
```
`grep -rn refresh lib/` confirms **no execution module ever converts it** into
`?refresh=true`. `refresh: true` is the *default* of `BulkImporter#import`, so the
documented "searchable right after import" behaviour silently does not exist for
ES/OpenSearch — reads return stale/empty results with no error.
(Typesense ignoring it is legitimate — `typesense.rb:23-25`.)

---

## Tier 2 — Silent wrong answers (correctness)

### F5. Failed PostgreSQL search is indistinguishable from "no results" **[verified]**
`postgresql_execution.rb:19-33` and `:381-393`

```ruby
 31: rescue StandardError => e
 32:   error_response(e)
...
387:   "total" => { "value" => 0, "relation" => "eq" },
391:   "error" => { "type" => ..., "reason" => ... }
```

**No log. And nothing reads the `"error"` key.** `grep` over `lib/` shows the only
consumers of an `error` key are `bulk_importer.rb:150` (a different payload) and
`adapter.rb:265` (the ES error parser). `ResponseFactory` passes the hash straight to
`Response::Records`, whose `#total` (`response.rb:14-23`) only reads `hits.total.value`.
The caller gets `total == 0`, `empty? == true`, no exception, no metric, no log line.

**Corroborating evidence from this repo's own history:** commit `0723ba0`
*"debug: surface swallowed PG search errors in CI"* added a `warn` to `error_response`,
and `cc15e7f` **reverted it**. Real errors were firing in CI and were silenced rather
than fixed.

By contrast **Elasticsearch/OpenSearch do this correctly**: `elasticsearch_execution.rb:19`
and `opensearch_execution.rb:20` pass `error_class: Noiseless::SearchError`, and
`adapter.rb:256-275` raises on any non-2xx. The PG/Typesense paths are missing this.

Same shape in Typesense: `typesense_execution.rb:206-221`, with the comment
*"Return empty response on error to maintain compatibility"*.

### F6. `vector_search` returns the **entire table** when pgvector is missing
`pgvector_support.rb:29` (and `:66`)
```ruby
29: return scope unless pgvector_available?   # scope is an unfiltered model.all
```
"Semantic search" degrades to "return every row, first 20". The `Model.execute` path
is accidentally guarded (`postgresql_execution.rb:37`), but the **public** helpers
`vector_search`/`hybrid_search` are not.

### F7. `Model#paginate` with no arguments crashes **[verified]**
`model.rb:62-65`
```ruby
62: def paginate(page: nil, per_page: nil)     # explicit nils OVERRIDE defaults
63:   @builder.paginate(page: page, per_page: per_page)
```
`QueryBuilder#paginate` has `page: 1, per_page: 20` defaults (`query_builder.rb:66`),
but explicit `nil` bypasses them → `AST::Paginate.new(nil, nil)` →
`adapter.rb:246-248` computes `(nil - 1)` → **`NoMethodError`**.
**[verified]** `NoMethodError: undefined method '-' for nil`.
Both `.paginate` and `.paginate(per_page: 20)` (the pattern used at
`test/opensearch_3_features_test.rb:201`) are broken. No test covers either.

### F8. Connectivity errors reported as "does not exist"
`postgresql_execution.rb:101-106` and `:124-129`
```ruby
101: def execute_index_exists?(index_name)
104: rescue StandardError
105:   false
```
A dead database, a permission error, or a typo'd model name all become `false`.
Callers — including `BulkImporter#delete_index` and the `create_index` gate — act on a
false negative.

### F9. `array_column?` uses a PostgreSQL-only API → `NoMethodError` → 0 results
`postgresql_execution.rb:437-439`
```ruby
438: model.columns_hash[field.to_s]&.array
```
`Column#array` exists **only** on the PostgreSQL subclass. On any other adapter this
raises, and `execute_search`'s rescue (F5) converts it into "0 results". A multi-DB app
whose search model sits on a different connection loses **every filtered search**.
Unit tests miss it because `test/postgresql_adapter_test.rb:87-93` uses `OpenStruct`
columns, which respond to any method.

### F10. Range filters unsupported on PostgreSQL — cross-adapter gap
`adapter.rb:225-226` (ES/OS) supports range filters; `postgresql_execution.rb:264-284`
only special-cases `geo_distance`, so `filter(:age, { gte: 18 })` falls to
`scope.where(field => value)` → `StatementInvalid` → swallowed to 0 results.
Same query works on ES/OS, returns nothing on PG.

### F11. `IndicesAPI#get` always raises `NoMethodError` **[verified]**
`lib/noiseless/adapters/indices_api.rb:12`
```ruby
12: @adapter.execute_index_exists?(index) ? { index => {} } : raise("Index not found")
```
`execute_index_exists?` is **private** (`es_compatible_execution.rb:14` → `:51`;
also `adapter.rb`). **[verified]** `NoMethodError: private method
'execute_index_exists?' called`. Second latent bug: the public `index_exists?` returns
an `Async::Task`, always truthy → would always report "index exists". PG overrides
IndicesAPI and is unaffected.

### F12. `resolve_model` runs `constantize` on an index name
`postgresql_execution.rb:397-414`
```ruby
410: model_name = index_name.to_s.classify
411: model_name.constantize
412: rescue NameError
413:   nil
```
`indexes:` is caller-supplied (`query_builder.rb:22-25`), and the constantized result is
never checked with `active_record_model?` — an index named `"string"` resolves to
`String`, then `model.all` raises and is swallowed to 0 results.

### F13. PostgreSQL vector search ignores pagination
`postgresql_execution.rb:35-58` never calls `apply_pagination` (:335), so
`paginate(page: 3)` on a vector query always returns page 1 — while the pagination
*metadata* still reports page 3, so the UI paginator disagrees with the data.

---

## Tier 3 — Reliability, resource & instrumentation defects

### F14. Callback double-writes the index, inside the transaction
`callbacks.rb:10-13`
```ruby
10: after_save    :update_search_index_on_save
12: after_commit  :update_search_index_on_commit, on: %i[create update]
```
Both call `update_search_index_async` → **two HTTP round-trips per save**, and the
`after_save` one fires *before commit*. A rolled-back transaction leaves documents in
the search index that do not exist in the database, with no compensating delete.

### F15. Background job swallows failures; `Rails.logger` may raise `NameError`
`search_index_update_job.rb:33-40` (identical shape at `callbacks.rb:120-129`)
```ruby
33: rescue StandardError => e
34:   if options[:raise_on_error]
36:   elsif (logger = Rails.logger)   # <-- Rails referenced unconditionally
```
* `ActiveJobSearchIndexUpdateJob#perform` (:68-70) calls `perform_now`, so **the job
  reports success on failure** → no retry, no dead-letter. A permanently broken index
  is invisible unless the app opts into `raise_on_error`.
* Outside Rails, the rescue handler itself raises `NameError: uninitialized constant
  Rails`, **replacing the original error**.

### F16. Controller runtime instrumentation is dead code **[verified]**
`instrumentation.rb:35-38,161-163`; `runtime_reset_middleware.rb:11`
```ruby
36: Thread.current[:noiseless_runtime] ||= 0
```
The write happens inside the `Async do … end` task (`adapter.rb:37`), which in async
2.45 runs in a **child Fiber on the same thread**. `Thread#[]` is **fiber-local**.
**[verified]** — value written in the child fiber is `nil` in the parent:
```
inside child fiber: 500
after Async (request fiber): nil
```
So `payload[:noiseless_runtime]` is always `0`, the `"Noiseless: %.1fms"` log line
(:169) never prints, and the middleware resets a slot nobody writes.
Fix: `ActiveSupport::IsolatedExecutionState` or a fiber-shared accumulator.

### F17. `ConnectionManager` lazy init is unsynchronized; no teardown
`connection_manager.rb:21-27`
```ruby
21: @clients[name] ||= begin ... Adapters.lookup(...) end
```
No mutex: two Puma threads can both build adapters, and the loser's `Async::HTTP::Client`s
(`http_transport.rb:59-63`) are never closed. There is no `close`/`reset` on the manager,
and `Noiseless.reset_config!` (`noiseless.rb:69-71`) resets only `@config`, **not**
`@connections` — so adapters built against stale config survive a reload.

### F18. Extension-detection failure is memoized permanently
`postgresql.rb:126` `@available_extensions ||= detect_extensions` + `:155 rescue → []`.
If detection fails once (DB not ready at boot, replica lag), `trgm_available?` /
`pgvector_available?` are cached `false` for the adapter's lifetime — the search path
degrades to plain ILIKE **forever**, and `vector_search` becomes fail-open (F6).

### F19. Introspection leaks HTTP clients
`introspection.rb:142-157`, `query_visualizer.rb:27-47` construct 3 adapters per call;
each allocates an `Async::HTTP::Client` per host and `HttpTransport#close` (:68-70)
is never called. `QueryVisualizer.compare_across_engines` also swallows all errors (:42).

### F20. Registry grows unboundedly under class reloading
`model_registry.rb:20-22` appends to `@models_by_index[index] <<` with no dedup. In
development the array grows each reload, and `multi_search.rb:210`
(`models_for_index(...).size == 1`) then silently stops resolving and falls through to
name inference. No locking on a process-wide `Singleton`.

---

## Tier 4 — Hygiene & consistency

| # | Issue | Location |
|---|---|---|
| F21 | `Rails.logger` unguarded in 5 places while the rest of the gem guards with `defined?(Rails)` | `callbacks.rb:125`, `search_index_update_job.rb:36`, `pgvector_support.rb:155`, `postgresql.rb:135,156` |
| F22 | Unsafe `YAML.load` while `noiseless.rb:88` correctly uses `YAML.safe_load` | `mapping.rb:76` |
| F23 | `public_send` on a caller-supplied scope name reaches `delete_all`/`destroy_all` | `bulk_importer.rb:80-86` |
| F24 | `Cursor.decode` `rescue → nil`; `from_record` uses `send` on an untrusted field name | `pagination.rb:87-93` — **dead code**, no callers in `lib/` or `test/` |
| F25 | `hybrid_search` binds `text_query` twice (line 86 binds, line 89 `bind_values.concat`) | `pgvector_support.rb:86-89` — latent, unreachable today |
| F26 | `quoted_column` uses `ActiveRecord::Base.connection` not `model.connection` — wrong quoting in multi-DB | `postgresql_execution.rb:449-451` |
| F27 | Typesense flattens nested `search_raw` hashes into URL params → silently invalid request | `typesense_execution.rb:181` |
| F28 | No `Gemfile.lock`; gemspec pins are ranges only | repo root |

---

## Verified-correct (do not "fix" these)

An audit that only lists problems is misleading. These were checked and are **right**:

* **ES/OpenSearch raise on failure** (`elasticsearch_execution.rb:19`,
  `opensearch_execution.rb:20` → `adapter.rb:256-275`). PG/Typesense should be made to match.
* **HTTP responses are not leaked** — `http_transport.rb:131-135` closes the real
  `Async::HTTP::Response` in an `ensure`; `BufferedResponse#close` is a no-op, so the
  many `ensure response&.close` blocks elsewhere are harmless.
* **Multi-`?` `where()` arity** in `apply_match` (:196-205) is valid; `sanitize_like`
  (:453-456) escapes `% _ \` and values are bind params — no injection, no LIKE bypass.
* **Array filters** (:286-291) produce correct `&&`/`@>` + cast semantics; `cast` comes
  from schema `sql_type`, not user data. Covered by `test/postgresql_integration_test.rb:213-238`.
* **Fail-closed for mapping-only fields** in match/multi_match/wildcard/range/prefix/filter
  is correct — **only the geo branch (F1) escapes this discipline.**
* **`apply_sorting` is injection-safe** (:324-325): direction is normalized to exactly
  `ASC`/`DESC`, with a quoted primary-key tiebreak.
* **`apply_range`** (:250-253) binds all four bounds and quotes the column.
* **No `eval`/`class_eval`/`instance_eval` on user data anywhere**; all blocks are
  developer-supplied literals.
* **Callbacks rescue narrowly** (`rescue Noiseless::Error`, :58-82) so non-Noiseless bugs
  still fail loudly — only the *handler* (F15) is broken.
* **Transport error taxonomy is good**: `TRANSPORT_ERRORS` → `ConnectionError`,
  HTTP non-2xx → `RequestError`/`SearchError` (`http_transport.rb:17-23,141-147`).
  This is the right pattern; PG/Typesense simply never use it.
* **`instrument` does not swallow exceptions** (`instrumentation.rb:14-16`).

---

## Proposed enhancements

### P0 — Make failure visible (fixes F5, F8, F9, F10, F12; the highest-value change)

Adopt the existing ES pattern in the PG and Typesense paths.

```ruby
# postgresql_execution.rb — replace error_response-as-empty-result
def execute_search(query_hash, model_class: nil, **)
  model = resolve_model(query_hash[:indexes], model_class)
  raise Noiseless::SearchError, "no model for #{query_hash[:indexes].inspect}" unless model
  ...
rescue Noiseless::Error
  raise                              # already normalised — never swallow
rescue StandardError => e
  raise Noiseless::SearchError, "postgresql search failed: #{e.message}"
end
```

Then make the error *surfaced* on the response rather than silently dropped:

```ruby
# response.rb — Base#initialize
def initialize(raw_response, model_class = nil)
  @raw_response = raw_response
  @model_class  = model_class
  raise Noiseless::SearchError, raw_response.dig("error", "reason") if raw_response["error"]
end
```

Ship it behind a flag first, since it is a **breaking change** for anyone currently
relying on "error == empty":

```ruby
attr_accessor :raise_on_search_error   # default: true in 0.9, false in 0.7.x
```

Rule of thumb to encode in the codebase: **`ConnectionError` and `SearchError` always
raise. Only an explicitly empty index returns an empty `hits` array.**

### P1 — Close the SQL injection holes (F1, F2)

Centralise identifier handling; require it, don't suggest it.

```ruby
# A single allow-list gate used by every clause builder
def column!(model, field)
  f = field.to_s
  raise Noiseless::Error, "unknown column #{f.inspect}" unless column?(model, f)
  quoted_column(model, f)
end
```

Geo becomes fail-closed and injection-free:

```ruby
def apply_geo_filter(scope, node, model)
  column = column!(model, node.field)          # raises instead of interpolating raw
  cfg    = node.value[:geo_distance]
  point  = cfg.values.find { |v| v.is_a?(Hash) && (v[:lat] || v["lat"]) && (v[:lon] || v["lon"]) }
  return scope.none if point.nil?               # fail CLOSED (matches apply_match:191)

  lat, lon = point[:lat] || point["lat"], point[:lon] || point["lon"]
  scope.where(
    "ST_DWithin(#{column}::geography, ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography, ?)",
    Float(lon), Float(lat), Float(parse_distance(cfg[:distance]))
  )
end
```

For pgvector, **bind the vector as a parameter** instead of interpolating:

```ruby
scope.select(Arel.sql("#{quoted_column(column)} <=> ?::vector AS vector_distance"), vector_literal)
```
and coerce in `AST::Vector#initialize`:
```ruby
raise ArgumentError, "embedding must be numeric" unless embedding.all? { |v| v.is_a?(Numeric) }
```
Fix `batch_store_embeddings` to use `quote_column_name(column)`, `quote_table_name(...)`,
and `model.connection` instead of `ActiveRecord::Base.connection`; drop the `::uuid`
assumption or derive the PK type from the schema (F26).

### P2 — Fix the data-loss and no-op paths (F3, F4, F7, F11)

* **Implement `create_index`** — or, until mappings are wired, have `force: true` use the
  adapters' existing `create_index` + `put_mapping`, and **refuse to delete before a
  successful recreate** (drop-and-create beats delete-then-create, since it cannot leave
  the index missing). Guard with `mapping` being a real callable, not a discarded local.
* **Honour `refresh:`** — thread it into the query string:
  `post_request("/_bulk?refresh=#{refresh ? 'true' : 'false'}", ...)` and
  `put_request("#{path}?refresh=#{refresh ? 'true' : 'wait_for'}", body)`. Also reject
  `refresh: true` on the `execute_bulk` `**_opts` instead of swallowing it.
* **`Model#paginate`** — delete the explicit `nil`s and let defaults apply:
  `def paginate(**opts) = @builder.paginate(**opts)`. Add a regression test for
  `.paginate`, `.paginate(per_page: 20)`, and `.paginate(page: 2)`.
* **`IndicesAPI#get`** — call the public `index_exists?(index).wait` and inspect the
  boolean, or make `execute_index_exists?` public. Remove the `Async::Task`-truthiness
  trap.

### P3 — Add the missing validation layer (the README's headline feature)

There is no `validate` in the gem. Add one at the AST boundary so every backend benefits:

```ruby
# lib/noiseless/ast/validation.rb
module Noiseless
  module AST
    module Validation
      IDENTIFIER = /\A[a-z_][a-z0-9_]*\z/i

      def self.field!(name)
        n = name.to_s
        raise ArgumentError, "illegal field #{name.inspect}" unless IDENTIFIER.match?(n)
        n
      end
      def self.distance!(d) ... end
      def self.limit!(n) = Integer(n).clamp(1, Pagination::MAX_PER_PAGE)
    end
  end
end
```
Apply in `DSL`/`QueryBuilder` entry points so hostile `params[:field]` is rejected once,
at the edge, instead of being interpolated into four different backends. Also:
`resolve_model` must assert `active_record_model?(constantized)` before use.

### P4 — Correct the callback & job lifecycle (F14, F15)

* Drop `after_save`/`after_destroy` index writes; keep only `after_commit`. This halves
  write volume and removes the rolled-back-transaction ghost documents.
* Make `ActiveJobSearchIndexUpdateJob#perform` **re-raise** so ActiveJob's retry/dead-letter
  machinery works; keep opt-in `raise_on_error: false` only for the inline-callback path.
* Replace bare `Rails.logger` with a single guarded helper used everywhere:
  ```ruby
  def self.logger = (Rails.logger if defined?(Rails) && Rails.respond_to?(:logger))
  ```

### P5 — Fix concurrency, leaks & instrumentation (F15→F16, F17-F20)

* **F16:** use `ActiveSupport::IsolatedExecutionState` (fiber-aware) for
  `noiseless_runtime`, or accumulate via `Concurrent::Map` keyed by request. Add a test
  asserting the log subscriber reports a non-zero value.
* **F17:** guard client creation with a `Monitor`; add `ConnectionManager#close` and make
  `reset_config!` close/discard `@connections` too.
* **F18:** memoise extension detection with a TTL/retry, or re-check when a query fails on
  a missing function.
* **F19:** wrap introspection adapters in `ensure` + `adapter.close`.
* **F20:** dedupe `@models_by_index[index]` on register (and reset the registry on reload).

### P6 — Close remaining consistency gaps (F21-F28)

`Rails.logger` guard (F21) · `YAML.safe_load` in `mapping.rb:76` (F22) ·
allow-list the scope passed to `public_send` in `bulk_importer.rb:80-86` (F23) ·
**delete the dead `Cursor`/`KeysetResult` code** or implement it properly (F24) ·
remove the duplicate bind in `hybrid_search` (F25) · `model.connection` for quoting
(F26) · reject nested hashes in Typesense `search_raw` (F27) · commit a `Gemfile.lock`
for CI reproducibility (F28).

---

## Test strategy — close the gaps that hid these bugs

Every Tier-1/Tier-2 defect above sat in an **untested** path. Add:

1. **Error-visibility contract test**, run against *all four* adapters:
   a stubbed backend 500 must raise `Noiseless::SearchError` — never return
   `total == 0`. This one test would have caught F5, F8, F9, F10, F12.
2. **Injection table test**: field names / embedding elements like
   `title) OR 1=1 --`, `"lat"` string keys, `nil` lat, `'[0.1]::vector) ... --'` →
   assert they raise or are escaped, never interpolated. *No geo test exists today.*
3. **Fail-open detector**: assert every PG clause builder either applies a predicate or
   returns `scope.none`. `return scope` in a clause builder is now a lint failure —
   grep-able invariant: `grep -n "return scope$" postgresql_execution.rb` must return
   nothing.
4. **`reindex` round-trip**: `force: true` must leave the index present, mapped, and
   searchable afterwards (catches F3).
5. **`refresh` honoured**: index then immediately search without an explicit
   `_refresh` (catches F4).
6. **Pagination matrix**: `.paginate`, `.paginate(per_page: 20)`, `.paginate(page: 2)`,
   and paginated vector search (catches F7, F13).
7. **Instrumentation**: assert `payload[:noiseless_runtime] > 0` inside a request
   (catches F16 — dead code always reads 0).
8. **Cross-adapter parity suite**: run the *same* query matrix (term, filter, range,
   array, geo, sort, paginate) against all four adapters and assert equivalent semantics.
   F1/F10/F13 are all parity gaps; this suite makes new ones impossible to introduce.
9. **Multi-DB / non-PostgreSQL-connection test** for `array_column?` (F9) — the
   `OpenStruct` stub in `test/postgresql_adapter_test.rb:87-93` is masking a real crash.
10. **Non-Rails smoke test**: load the gem and drive the PG adapter with `Rails` undefined
    (catches F15/F21 `NameError` masking).

Add `Lint/` or a small custom cop for the gem's own invariants:
`return scope` inside a PG clause builder (fail-open), unguarded `Rails.logger`,
`YAML.load`, and interpolation into a SQL string literal.

---

## Suggested sequencing

| Phase | Work | Rationale |
|---|---|---|
| 1 | P0 error visibility behind a flag | Unmasks every other latent bug; biggest production risk |
| 2 | P1 geo + pgvector injection | Security; same 20 lines, both defects |
| 3 | P2 `create_index` / `refresh` / `paginate` / `IndicesAPI` | Data loss + user-visible breakage |
| 4 | P3 validation layer + P4 callbacks/job | Prevents recurrence at the boundary |
| 5 | P5 concurrency/instrumentation + P6 consistency | Correctness & hygiene |
| — | Test items 1-10 alongside each phase | Each maps 1:1 to a bug it would have caught |

Fix order rationale: **P0 before P1**, because once errors raise, the remaining fail-open
paths become loud instead of silent, which also makes the P1 fixes verifiable in
integration tests instead of only by SQL inspection.