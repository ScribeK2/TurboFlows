# Performance TDD Design

Date: 2026-02-28
Status: Approved

## Context

Kizuflow is being deployed as an internal production tool. Initial rollout targets ~100 users (one department) with potential expansion to ~1500 users (company-wide). Usage pattern is read-heavy: agents primarily look up and follow existing workflows during calls/chats, with fewer concurrent editors.

Infrastructure: PostgreSQL (production), Redis available for caching and Action Cable.

## Approach

Bottom-up query optimization using TDD. Write performance tests that assert query counts and response time bounds (RED), then fix each bottleneck to make tests pass (GREEN). Work layer by layer: database indexes, model query optimization, caching, infrastructure config.

## Bottlenecks Identified

Ranked by impact on read-heavy workload:

1. **Recursive N+1 in group sidebar** — `workflows_count` calls N+1 `descendants` method for every group rendered, firing dozens of queries per page load.
2. **Missing eager loading in workflow list** — `primary_group` and `can_be_edited_by?` fire 2-4 extra queries per workflow item without `includes`.
3. **Redcarpet instantiation per call** — `description_text` creates a new Markdown renderer every invocation with no memoization.
4. **No production cache store** — Fragment caching falls back to per-process memory store, no cross-worker benefit.
5. **SubflowValidator recursive DB hits** — `Workflow.find_by` called per node in recursive DFS on every save including autosave.
6. **WorkflowChannel re-queries on every message** — No memoization; autosave fires `Workflow.find` every few seconds per editor.
7. **`assets.compile = true` in production** — Live Sprockets compilation on first request; only 1hr cache for static assets.
8. **DB connection pool undersized** — Pool of 7 is too small for multi-worker Puma (needs 10+ per worker).
9. **Missing `updated_at` index on workflows** — Default sort order does a full table scan.
10. **No background jobs** — PDF export, draft cleanup, and subflow validation all block web threads.

## Test Infrastructure

### Conventions

- Tests live in `test/performance/`
- Shared helper: `test/support/performance_helper.rb`
- Custom assertions: `assert_max_queries(n) { block }`, `assert_completes_within(seconds) { block }`
- Data volumes: 200 workflows, 30 groups (4 levels deep), 20 users across roles
- Each test file is self-contained with its own setup

### Test File Map

| File | Purpose |
|------|---------|
| `test/support/performance_helper.rb` | Shared helpers, query counter, data seeding |
| `test/performance/indexes_test.rb` | Index effectiveness: `updated_at` sort, full-text search, `steps_count` |
| `test/performance/workflow_list_query_test.rb` | Workflow list page ≤15 queries for 200 workflows |
| `test/performance/group_sidebar_query_test.rb` | Group sidebar ≤5 queries for 30 groups |
| `test/performance/subflow_validation_test.rb` | SubflowValidator ≤3 queries for 200-step workflow |
| `test/performance/caching_test.rb` | Redis cache store, memoization, counter cache |
| `test/performance/action_cable_test.rb` | Channel memoization, broadcast payload size |

## Layer 1: Database Indexes

### Migrations

- `add_index :workflows, :updated_at` — supports default sort order
- `add_column :workflows, :steps_count, :integer, default: 0` — cached column replacing `json_array_length` sort
- PostgreSQL `tsvector` index on `workflows.title + workflows.description` for full-text search (SQLite fallback: `LIKE` for dev/test)
- Composite indexes on `scenarios` for common query patterns

### Test Assertions

- Workflow list sorted by `updated_at` completes within time bounds at 200 rows
- Full-text search query completes within bounds
- Steps count sort uses cached column, not JSON function

## Layer 2: N+1 Query Elimination

### Workflow List (WorkflowsController#index)

**Problem**: `primary_group` and `can_be_edited_by?` fire 2-4 queries per workflow item.
**Fix**: Add `includes(group_workflows: :group, user: :groups)` to controller scope.
**Test**: Loading 200 workflows uses ≤15 queries total.

### Group Sidebar (_group_sidebar_item.html.erb)

**Problem**: `workflows_count` calls recursive `descendants` (1 query per group per level).
**Fix**: Replace recursive Ruby with single CTE query via `descendant_ids`; add counter cache column.
**Test**: Rendering 30 groups uses ≤5 queries.

### Group Ancestors/Descendants

**Problem**: `ancestors` and `descendants` methods fire 1 query per level recursively.
**Fix**: Single recursive CTE query or preloaded ancestry path.
**Test**: `ancestors` for depth-4 group uses ≤2 queries.

### SubflowValidator

**Problem**: `Workflow.find_by` called per node in recursive DFS.
**Fix**: Batch-load all referenced workflows in one query upfront, pass hash to recursive method.
**Test**: Validating 200-step workflow with 10 subflows uses ≤3 queries.

### View-Level Queries

**Problem**: `Workflow.find_by` inside `_subflow_selector.html.erb`.
**Fix**: Preload in controller, pass via locals.
**Test**: Zero DB queries inside view partials.

## Layer 3: Caching & Memoization

### Production Cache Store

- Configure `config.cache_store = :redis_cache_store` in `production.rb`
- Enables cross-worker fragment cache sharing

### Memoization

- `description_text`: Class-level constant for `Redcarpet::Markdown` instance (thread-safe, immutable)
- `WorkflowChannel`: Memoize `Workflow.find` per connection lifecycle
- `can_be_viewed_by?` / `can_be_edited_by?`: Cache per request via instance variable

### Counter Caches

- Add `workflows_count` counter cache on `groups` table via `group_workflows`
- Eliminates recursive count in sidebar

### Test Assertions

- Second render of workflow list ≤3 queries (cache hits)
- `description_text` called 200 times allocates 1 Redcarpet instance
- Group sidebar with warm counter cache ≤2 queries

## Layer 4: Infrastructure & Config

| Issue | Fix |
|-------|-----|
| `assets.compile = true` | Set to `false`; ensure `assets:precompile` in deploy |
| Static asset cache 1hr | Set `max-age=31536000` for fingerprinted assets |
| DB pool undersized (7) | `pool: RAILS_MAX_THREADS * WEB_CONCURRENCY + 2` |
| Action Cable full payload | Broadcast only changed step diffs, not entire `steps` array |

## Out of Scope (Future)

- **Sidekiq/background jobs** — Deferred to reduce operational complexity. PDF export and draft cleanup remain synchronous.
- **HTTP ETag/Last-Modified caching** — Browser-level caching for workflow list and show actions.
- **k6 load testing at scale** — Scaling existing k6 script to 100-1500 VUs for end-to-end validation.
- **Database read replicas** — Not needed at 1500 users with query optimization in place.
