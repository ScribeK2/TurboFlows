require "test_helper"

class ConfigTest < ActiveSupport::TestCase
  test "database pool accounts for web concurrency in production config" do
    db_config = File.read(Rails.root.join("config/database.yml"))

    # Pool should reference WEB_CONCURRENCY, not just RAILS_MAX_THREADS
    assert_match(/WEB_CONCURRENCY/, db_config,
      "Production DB pool should account for WEB_CONCURRENCY (Puma workers)")
  end

  test "production cache store is not commented out" do
    prod_config = File.read(Rails.root.join("config/environments/production.rb"))

    # There should be an active (non-commented) cache_store line
    active_cache_lines = prod_config.lines.select { |l|
      l.match?(/config\.cache_store/) && !l.strip.start_with?("#")
    }
    assert active_cache_lines.any?,
      "Production should have an active cache_store configuration"
  end
end
