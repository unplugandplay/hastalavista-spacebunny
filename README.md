# Noiseless

Async-first search abstraction for Rails with multi-backend support (OpenSearch, Elasticsearch, Typesense, PostgreSQL).

## Features

- **Chainable DSL** — fluent query builder with runtime validation
- **Multi-backend** — OpenSearch, Elasticsearch, Typesense, PostgreSQL adapters
- **Async-first** — built on Ruby 3.4+ fiber scheduler with non-blocking I/O
- **HTTP/2 connection pooling** — persistent connections via `Async::Pool`
- **Rails integration** — Railtie with log subscriber and controller runtime tracking
- **Lazy loading** — adapters loaded on-demand, test files excluded from production
- **Fail-loud search** — a backend error raises instead of silently returning zero results

## Installation

```ruby
gem "noiseless"
```

`noiseless` is a Rails gem. It requires Ruby >= 3.4 and Rails >= 8.1.

## Configuration

Create `config/noiseless.yml`:

```yaml
development:
  default: primary
  connections:
    primary:
      adapter: elasticsearch
      hosts:
        - http://localhost:9201
    opensearch:
      adapter: open_search
      hosts:
        - http://localhost:9202
    typesense:
      adapter: typesense
      hosts:
        - http://localhost:8109
    postgresql:
      adapter: postgresql

production:
  default: primary
  connections:
    primary:
      adapter: opensearch
      hosts:
        - <%= ENV['OPENSEARCH_URL'] %>
    typesense:
      adapter: typesense
      hosts:
        - <%= ENV['TYPESENSE_URL'] %>
    postgresql:
      adapter: postgresql
```

## Usage

### Defining a Search

```ruby
class Company::Search < Noiseless::Model
  index_name 'companies'

  def by_name(name)
    multi_match(name, [:name, :name_aliases])
  end

  def suppliers_only
    filter(:company_type, 'supplier')
  end
end
```

### Executing Searches

All `.execute` calls return `Async::Task` objects. Use `Sync` to wait for results, or use the `_sync` convenience methods:

```ruby
# Convenience method (recommended for simple cases)
results = Company::Search.new.by_name('tech').execute_sync

# Class-level convenience
results = Company::Search.search_sync do |s|
  s.match(:name, 'tech')
  s.limit(10)
end

# Explicit Sync block
results = Sync do
  Company::Search.new
    .by_name('technology')
    .suppliers_only
    .limit(20)
    .execute
    .wait
end
```

### Concurrent Searches

```ruby
Async do |task|
  companies_task = Company::Search.new.match(:name, 'tech').execute
  products_task  = Product::Search.new.match(:name, 'tech').execute

  companies = companies_task.wait
  products  = products_task.wait
end
```

For best performance, run independent searches concurrently within a single `Async` block rather than creating separate `Sync` blocks per search.

### Advanced Queries

```ruby
results = Company::Search.new
  .match(:name, 'electronics')
  .filter(:status, 'active')
  .geo_distance(:location, lat: 40.7128, lon: -74.0060, distance: '50km')
  .sort(:created_at, :desc)
  .paginate(page: 1, per_page: 10)
  .execute_sync
```

### Rails Integration

```ruby
class CompaniesController < ApplicationController
  def search
    @results = Company::Search.new
      .by_name(params[:q])
      .limit(20)
      .execute_sync

    render json: @results
  end
end
```

## Testing

Add to `test/test_helper.rb`:

```ruby
require 'noiseless/test_helper'
require 'noiseless/test_case'
```

### With Noiseless::TestCase (automatic VCR cassettes)

```ruby
class CompanySearchTest < Noiseless::TestCase
  def test_search_by_name
    # Cassette auto-named: company_search/search_by_name
    search = Company::Search.new.by_name('test')
    assert_search_results(search)
  end
end
```

### With manual VCR control

```ruby
class CompanySearchTest < ActiveSupport::TestCase
  include Noiseless::TestHelper

  def test_custom_search
    noiseless_cassette(record: :new_episodes) do
      results = Company::Search.new.by_name('test').execute_sync
      assert results.any?
    end
  end
end
```

### Running Tests Locally

```bash
docker compose up -d postgres elasticsearch opensearch typesense
bin/test
```

`bin/test` expects all four local services from `docker-compose.yml`, including PostgreSQL on `:5432`.
Default ports match `docker-compose.yml`: PostgreSQL `:5432`, Elasticsearch `:9201`, OpenSearch `:9202`, Typesense `:8109`. Override via env vars:

```bash
ELASTICSEARCH_PORT=9200 OPENSEARCH_PORT=9201 TYPESENSE_PORT=8108 bin/test
```

For a release smoke test that does not require the dummy app or local services:

```bash
bundle exec rake release:check
```

## Debug Mode

```ruby
ENV['NOISELESS_VERBOSE'] = 'true'
```

### Error handling

Search failures raise. A backend that is unreachable, rejects the query, or has a
permissions problem raises a `Noiseless::Error` subclass rather than returning an
empty result set — so an outage can never be mistaken for "no matching documents".

| Exception | Raised when |
|---|---|
| `Noiseless::ConnectionError` | The backend could not be reached (refused, DNS, reset, timeout) |
| `Noiseless::SearchError` | The backend was reached but rejected the query or failed to execute it |
| `Noiseless::RequestError` | A non-2xx HTTP response from the backend |

```ruby
begin
  results = Company::Search.new.by_name(params[:q]).execute_sync
rescue Noiseless::ConnectionError
  # Backend unreachable — surface a retry or a degraded page
rescue Noiseless::SearchError
  # Query rejected or failed — log and alert
end
```

This applies uniformly to all four backends. To restore the legacy behaviour where a
backend error yields an empty result set (not recommended — it hides outages):

```ruby
Noiseless.config.raise_on_search_error = false
# or: NOISELESS_RAISE_ON_SEARCH_ERROR=false
```

With the flag off, failures are logged and the response exposes the backend's error:

```ruby
results = Company::Search.new.by_name("tech").execute_sync
results.error?       # => true
results.error_reason # => "Failed to parse query"
```

### Constraints the PostgreSQL adapter enforces

The PostgreSQL adapter can only filter on real columns. A clause it cannot enforce
**fails closed** — it returns no rows rather than silently widening the result set.
This applies to `match`, `multi_match`, `wildcard`, `range`, `prefix`, `filter` and
`geo_distance`. For example, filtering or sorting on a denormalized field that exists
only in the search index yields an empty result instead of every row.

Range filters work the same as on Elasticsearch/OpenSearch:

```ruby
Company::Search.new.filter(:age, { gte: 18, lte: 65 }).execute_sync
```

Semantic search requires the `pgvector` extension. Without it a vector query raises
`Noiseless::SearchError` rather than degrading to an unfiltered table scan.

### Indexing behaviour

Auto-indexing writes on `after_commit` only — never `after_save`. A rolled-back
transaction therefore cannot leave documents in the search index that do not exist in
the database. This also means one write per save instead of two.

Background indexing jobs (`auto_index async: true`) re-raise on failure so ActiveJob
and Sidekiq retry and dead-letter them. Set `raise_on_error: false` on
`auto_index` to log-and-continue instead:

```ruby
auto_index enabled: true, async: true, raise_on_error: false
```

`reindex` deletes and then **recreates** the index, raising if it cannot be restored
rather than bulk-indexing into a missing index. Writes honour `refresh:` — documents
are searchable when the call returns:

```ruby
Company::Search.new.import(Company.all, refresh: true)  # searchable immediately
Company::Search.new.import(Company.all, refresh: false) # relies on periodic refresh
```

## Contributing

1. Follow Rails conventions for code organization
2. Test helpers must remain separate from core functionality
3. Add tests for new features using the provided test utilities

## License

BSD 3-Clause License — See [LICENSE.txt](LICENSE.txt)
