require "test_helper"

# index_scenarios_for_analytics made Rails' prepared statements dangerous once
# they went generic, on their sixth run on a connection: a generic plan can't
# see how wide `started_at BETWEEN $1 AND $2` is, so for `ORDER BY id LIMIT n`
# it fetched and sorted a whole 90-day range. On the load-test replica the
# Analytics samples went from 5 ms to 7-14 s. Planning each run with its own
# values is what keeps the index safe, so the setting must not quietly go.
class DatabasePlanCacheModeTest < ActiveSupport::TestCase
  test "production plans every prepared statement with its own values" do
    production = Rails.application.config.database_configuration.fetch("production")

    %w[primary queue].each do |database|
      assert_equal "force_custom_plan", production.dig(database, "variables", "plan_cache_mode"),
                   "production #{database} in config/database.yml"
    end
  end

  test "a PostgreSQL connection runs with that setting" do
    skip "plan_cache_mode is PostgreSQL's" unless ActiveRecord::Base.connection.adapter_name.downcase.include?("postgresql")

    assert_equal "force_custom_plan", ActiveRecord::Base.connection.select_value("SHOW plan_cache_mode")
  end
end
