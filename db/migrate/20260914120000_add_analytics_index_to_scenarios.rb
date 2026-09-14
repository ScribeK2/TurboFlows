# Analytics reads a range of runs, and a 90-day range matches nearly every row
# in `scenarios` (live runs are kept 90 days), so an index on started_at alone
# loses to reading the table. What a row costs is its execution_path, about
# 1.2 KB: on the load-test replica the table was 730 MB for 500k runs, and each
# 90-day page read it end to end seven times. INCLUDE carries every column those
# queries read, so they answer from this index (46 MB there) without touching a
# row. That needs the visibility map, so autovacuum has to keep up.
#
# The index sets a trap that config/database.yml closes. Once a prepared
# statement goes generic (its sixth run on a connection), the planner can't see
# how wide `started_at BETWEEN $1 AND $2` is, and for `ORDER BY id LIMIT n` it
# chose this index, fetched the whole range and sorted it: the 5,000-run
# samples went from 5 ms to 7-14 s, and a CSV export would have done that per
# batch. plan_cache_mode = force_custom_plan plans each run with its values.
#
# SQLite has neither INCLUDE nor a concurrent build, and schema.rb is dumped
# from SQLite, so it records the plain index.
class AddAnalyticsIndexToScenarios < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_scenarios_for_analytics".freeze
  COLUMNS = %i[id workflow_id user_id status outcome purpose completed_at duration_seconds
               parent_scenario_id handed_off_from_id run_origin_id].freeze

  def up
    if postgresql?
      add_index :scenarios, :started_at, name: INDEX_NAME, include: COLUMNS, algorithm: :concurrently
    else
      add_index :scenarios, :started_at, name: INDEX_NAME
    end
  end

  def down
    remove_index :scenarios, name: INDEX_NAME, algorithm: (postgresql? ? :concurrently : nil)
  end

  private

  def postgresql?
    connection.adapter_name.downcase.include?("postgresql")
  end
end
