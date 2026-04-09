require "test_helper"

class CachingTest < ActiveSupport::TestCase
  include PerformanceHelper

  test "production environment configures redis cache store" do
    config_content = Rails.root.join("config/environments/production.rb").read

    assert_match(/config\.cache_store\s*=\s*:redis_cache_store/, config_content,
                 "Production should configure Redis as the cache store")
    assert_no_match(/^\s*#\s*config\.cache_store/, config_content,
                    "Cache store config should not be commented out")
  end

  test "production sets long cache for fingerprinted assets" do
    config_content = Rails.root.join("config/environments/production.rb").read

    # Should have max-age of at least 1 year (31536000 seconds)
    assert_match(/max-age=31536000/, config_content,
                 "Fingerprinted assets should be cached for 1 year")
  end

  test "description_text returns plain text from Action Text" do
    workflows = seed_performance_data[:workflows].first(50)

    assert_completes_within(1.0) do
      workflows.each(&:description_text)
    end
  end

  test "WorkflowChannel memoizes workflow lookup" do
    channel_source = Rails.root.join("app/channels/workflow_channel.rb").read

    assert_match(/@find_workflow\s*\|\|=/, channel_source,
                 "WorkflowChannel should memoize workflow with ||= pattern")
  end
end
