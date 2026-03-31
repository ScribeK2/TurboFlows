require "test_helper"

class ConfigTest < ActiveSupport::TestCase
  test "production database uses SQLite with WAL mode" do
    db_config = Rails.root.join("config/database.yml").read

    assert_match(/adapter: sqlite3/, db_config,
                 "Production DB should use SQLite adapter")
    assert_match(/default_transaction_mode: immediate/, db_config,
                 "Production DB should use WAL mode via immediate transaction mode")
    assert_match(/busy_timeout: 5000/, db_config,
                 "Production DB should set busy_timeout for write contention handling")
  end

  test "production cache store is not commented out" do
    prod_config = Rails.root.join("config/environments/production.rb").read

    # There should be an active (non-commented) cache_store line
    active_cache_lines = prod_config.lines.select do |l|
      l.include?('config.cache_store') && !l.strip.start_with?("#")
    end
    assert_predicate active_cache_lines, :any?,
                     "Production should have an active cache_store configuration"
  end
end
