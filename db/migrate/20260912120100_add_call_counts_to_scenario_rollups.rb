# Calls beside runs on the rollup grain (ISSUE-003).
#
# All time reads rollups, so without these its headline would count workflow
# runs while every other range counts calls. A call is rolled up on the grain of
# where it started — the origin's workflow, day and purpose — with the outcome it
# ended with. Durations are a sum and a count, never an average, as runs' are.
#
# No backfill. Days already rolled are frozen once outside the refresh window,
# and their raw runs are partly deleted, so recomputing calls for them would
# undercount — the trap ScenarioRollupBuilder is built around. They keep zero
# calls, and the analytics page says from when calls are counted.
class AddCallCountsToScenarioRollups < ActiveRecord::Migration[8.1]
  def change
    add_column :scenario_rollups, :calls_count, :integer, default: 0, null: false
    add_column :scenario_rollups, :call_duration_sum_seconds, :integer, default: 0, null: false
    add_column :scenario_rollups, :call_duration_count, :integer, default: 0, null: false
  end
end
