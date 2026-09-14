# Tells PostgreSQL how many days a range of runs spans. The Analytics headline
# groups calls by `started_at::date`, and with no statistics on that expression
# PostgreSQL guessed ~437k groups for 496k calls. So it sorted them on disk
# instead of hashing the 453 there were, and one 90-day page in four took 2.5 s
# instead of 0.4 on the load-test replica. With these statistics it groups in
# memory.
#
# ANALYZE fills them in now; left to autovacuum, a quiet table can go days
# without one. schema.rb is dumped from SQLite and can't record statistics, so a
# PostgreSQL database loaded from it (the test database) has none. The tests
# check figures, not plans.
class AddStartedDayStatisticsToScenarios < ActiveRecord::Migration[8.1]
  def up
    return unless postgresql?

    execute "CREATE STATISTICS IF NOT EXISTS scenarios_started_day ON ((started_at::date)) FROM scenarios"
    execute "ANALYZE scenarios"
  end

  def down
    return unless postgresql?

    execute "DROP STATISTICS IF EXISTS scenarios_started_day"
  end

  private

  def postgresql?
    connection.adapter_name.downcase.include?("postgresql")
  end
end
