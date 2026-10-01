# DevLog

Append-only record of engineering work on `noiseless`. Newest first.

---

## 2026-10-01 — Code audit and remediation (28 flaws)

A full audit of the 0.7.2 codebase (69 files / 7,692 LOC) followed by fixes and
regression tests. Findings are catalogued in [`bunny.md`](bunny.md).

### Context

The README advertised "runtime validation" and safe multi-backend abstraction. The
audit found the second claim was only partly true: Elasticsearch and OpenSearch
handled errors correctly (they raise), but PostgreSQL and Typesense silently converted
every failure into an empty result set. A production search outage was therefore
indistinguishable from "no matching documents" — no exception, no log line, no metric.

A telling detail from the repo's own history surfaced during the audit:

- `0723ba0` "debug: surface swallowed PG search errors in CI" added a `warn` call to
  the PostgreSQL `error_response` helper
- `cc15e7f` **reverted it**

Real errors were firing in CI and were silenced rather than diagnosed. That is the
root cause of the whole Tier 2 class of defects.

### Verification approach

Before changing anything I got the test suite running locally (Docker was unavailable,
so a local PostgreSQL 13 with pgvector/pg_trgm/unaccent was started) and recorded a
baseline: **247 runs, 17 failures — all connection-refused errors for live
Elasticsearch/OpenSearch/Typesense, zero logic failures.**

Several claims in the audit were then confirmed by execution rather than inspection:

- `IndicesAPI#get` raised `NoMethodError` (it called a private method)
- `Model#paginate` raised `NoMethodError: undefined method '-' for nil`
- the runtime instrumentation counter was always `0` (`Thread.current[]` is
  fiber-local, and the write happened inside an Async task fiber)
- `refresh:` never reached any HTTP request
- the geo filter dropped its predicate entirely for string-keyed or nil coordinates

Typesense-dependent tests were additionally verified against a stub HTTP server on
`:8109` to emulate CI, confirming the behaviour change is safe where the backend is
actually reachable.

### Security fixes

**SQL injection + fail-open geo filter** (`postgresql_execution.rb`)
`apply_geo_filter` interpolated the field name raw — the only clause builder in the
file missing both `quoted_column` and the `column?` allow-list that every sibling
already used. It also returned the *unfiltered* scope when the coordinate point was
missing, so "articles near Paris" returned every published row worldwide. Now quotes
the identifier, accepts string-keyed coordinates, coerces values with `Float()`, and
fails closed via `scope.none`.

**pgvector embedding injection** (`pgvector_support.rb`)
Embeddings were interpolated into a single-quoted SQL literal in a SELECT list and
ORDER BY, and `AST::Vector` performed no type coercion — a string element could break
out into arbitrary SQL. Added `vector_literal`, which coerces every element to a
finite `Float`, and validation at the AST boundary.

**`batch_store_embeddings`** used unquoted identifiers and a hardcoded `::uuid` cast
that raised on any non-UUID primary key. Now quotes via `model.connection` and derives
the primary key's SQL type from the schema.

**`resolve_model`** ran `constantize` on a caller-supplied index name and only
checked `NameError`. Switched to `safe_constantize` plus an `active_record_model?`
check, so an index named `"string"` resolves to nil rather than exploding later.

### Correctness fixes

**Fail-loud search.** PostgreSQL and Typesense now raise `Noiseless::SearchError`,
matching the existing Elasticsearch/OpenSearch behaviour. The old `error_response`
payload carried an `"error"` key that nothing in `lib/` ever read. Gated behind
`Noiseless.config.raise_on_search_error` (default true, `NOISELESS_RAISE_ON_SEARCH_ERROR=false`
to restore legacy behaviour) because it is a breaking change for anyone relying on
"error means empty".

`Response::Base` now raises on a response body containing an error, and exposes
`#error?` / `#error_reason` when the flag is off.

**`reindex` data loss.** `BulkImporter#create_index` was a stub whose body was a
commented-out call, so `reindex` deleted the index and then bulk-indexed into a
non-existent one. Now implemented via the adapters' `create_index(mappings:)`, and
`recreate_index!` raises if the index cannot be restored. `delete_index` no longer
swallows auth/connectivity errors as "index did not exist".

**`refresh:` honoured.** The option was accepted by the public API and discarded by
every execution module. Now translated to `?refresh=wait_for` on bulk, index, update
and delete for ES/OpenSearch.

**Fail-closed vector search.** `vector_search`/`hybrid_search` returned the unfiltered
scope when pgvector was missing, so "semantic search" became "return every row".
Now returns `scope.none`.

**`array_column?` crash.** Called `Column#array`, which exists only on the PostgreSQL
adapter's Column subclass — raising `NoMethodError` on any other connection. The unit
tests missed it because they used `OpenStruct` columns that respond to everything.

**Range filter parity.** `filter(:age, { gte: 18 })` worked on ES/OpenSearch but raised
on PostgreSQL. Now translated into a `Range` node.

**Pagination.** `Model#paginate` forwarded explicit `nil`s that overrode
`QueryBuilder#paginate`'s defaults, producing `AST::Paginate.new(nil, nil)`. Vector
search ignored pagination entirely while still reporting the requested page in its
metadata.

**`IndicesAPI#get`.** Called the private `execute_index_exists?` (always
`NoMethodError`) and would have treated the returned `Async::Task` as truthy anyway.

**`MapJoin` / duplicated binds.** `hybrid_search` bound `text_query` twice and
interpolated weights raw.

### Reliability fixes

**Callbacks double-write.** Both `after_save` and `after_commit` indexed the record,
so every save issued two HTTP round-trips and the `after_save` write ran *before*
commit — a rollback left ghost documents in the index with nothing to remove them.
Now `after_commit` only.

**Background jobs reported false success.** `perform_now` swallowed every error, so
ActiveJob considered the job successful: no retry, no dead-letter, and a permanently
broken index went unnoticed. Now re-raises when a queue backend is present.

**`Rails.logger` outside Rails.** Five call sites referenced `Rails` unguarded,
including inside `rescue` handlers — masking the original error with
`NameError: uninitialized constant Rails`. Added `Noiseless.logger`, nil-safe
everywhere.

**`YAML.load`** in `Mapping.load_settings_from_file` replaced with `YAML.safe_load`,
consistent with `noiseless.rb`.

### Tests

Added `test/flaw_regression_test.rb` — 35 tests, each labelled with the flaw it pins
down (F1, F2, F5, F6, F7, F9, F10, F11, F12, F13, F14, F21).

Two rounds of verification were needed. The first version of the suite aborted in
`setup` against the original code, which proved nothing about individual tests. Reverting
each fix individually exposed two weak tests:

- the F7 pagination tests passed against the buggy `paginate` — an indentation mismatch
  meant the revert never applied; fixed the check and confirmed both tests then fail
- the F6 fail-closed test passed against the fail-open code because `scope.count` was
  `0` regardless of the predicate — rewrote it to compare generated SQL

Final state: **282 runs (up from 247), 792 assertions, zero regressions against the
baseline.** `rubocop` clean across 73 files.

### Notes / follow-ups

- The instrumentation counter (`instrumentation.rb`) still uses `Thread.current[]`,
  which is fiber-local, so the reported runtime remains `0` under an Async scheduler.
  The correct fix is `ActiveSupport::IsolatedExecutionState`; deliberately left out of
  this change since it alters log output and needs its own test.
- `ConnectionManager#client` still has an unsynchronized lazy init (two Puma threads can
  both build an adapter) and no `close`. Worth a follow-up with a teardown path.
- Extension detection is memoised permanently; a transient failure at boot degrades
  search to plain ILIKE for the adapter's lifetime.
- `Postgres::IndicesAPI` is a separate class from the shared one and needs the same
  review.
- Dead code: `Pagination::Cursor` and `KeysetResult` have no callers; `Cursor.decode`
  uses `send` on an untrusted field name. Recommend deleting rather than maintaining.
- Local PostGIS was unavailable, so geo predicates are asserted at the SQL level rather
  than executed. CI uses `postgis-with-extensions` and can execute them.