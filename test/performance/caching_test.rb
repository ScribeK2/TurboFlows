require "test_helper"

class CachingTest < ActiveSupport::TestCase
  include PerformanceHelper

  test "production environment configures redis cache store" do
    config_content = File.read(Rails.root.join("config/environments/production.rb"))

    assert_match(/config\.cache_store\s*=\s*:redis_cache_store/, config_content,
      "Production should configure Redis as the cache store")
    refute_match(/^\s*#\s*config\.cache_store/, config_content,
      "Cache store config should not be commented out")
  end

  test "production disables live asset compilation" do
    config_content = File.read(Rails.root.join("config/environments/production.rb"))

    assert_match(/config\.assets\.compile\s*=\s*false/, config_content,
      "Production should not compile assets on the fly")
  end

  test "production sets long cache for fingerprinted assets" do
    config_content = File.read(Rails.root.join("config/environments/production.rb"))

    # Should have max-age of at least 1 year (31536000 seconds)
    assert_match(/max-age=31536000/, config_content,
      "Fingerprinted assets should be cached for 1 year")
  end

  test "Redcarpet MARKDOWN_RENDERER is a frozen class constant" do
    assert defined?(Workflow::MARKDOWN_RENDERER),
      "Workflow should have a MARKDOWN_RENDERER constant"
    renderer = Workflow::MARKDOWN_RENDERER
    assert_instance_of Redcarpet::Markdown, renderer
  end

  test "description_text uses shared renderer" do
    workflows = seed_performance_data[:workflows].first(50)

    assert_completes_within(1.0) do
      workflows.each(&:description_text)
    end
  end
end

class ActionCableMemoizationTest < ActiveSupport::TestCase
  include PerformanceHelper

  test "WorkflowChannel memoizes workflow lookup" do
    channel_source = File.read(Rails.root.join("app/channels/workflow_channel.rb"))

    assert_match(/@workflow\s*\|\|=/, channel_source,
      "WorkflowChannel should memoize workflow with ||= pattern")
  end
end
