# Technical Debt Tracker

Items identified in the April 2026 Rails audit that are not urgent but should be
addressed as the application grows.

## 1. System/Integration Test Coverage

**Status:** Partially addressed (added 3 system tests, bringing total to 5)
**Target:** 10+ system tests covering all critical user journeys
**Priority:** Medium — add tests as features are modified

## 2. Service Directory Organization

**Status:** Not started
**Recommendation:** Gradually migrate well-named services from `app/services/` to
namespaced models in `app/models/` (e.g., `Workflows::Publisher`, `Steps::Builder`)
per thoughtbot Ruby Science conventions.
**Priority:** Low — current structure is functional, names are domain-correct

## 3. Analytics Step Performance Denormalization

**Status:** Not started (documented in code at analytics_controller.rb)
**Trigger:** When step_performance analytics queries become noticeably slow
**Recommendation:** Create `step_executions` table (step_id, scenario_id,
duration_seconds, started_at) and populate during scenario execution.
Replace Ruby iteration with SQL aggregation.
**Priority:** Low — current O(n) approach is acceptable at current scale
