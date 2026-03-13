require "test_helper"

class ActionCableBroadcastTest < ActiveSupport::TestCase
  include PerformanceHelper

  test "autosave broadcast does not send full steps array" do
    channel_source = File.read(Rails.root.join("app/channels/workflow_channel.rb"))

    # Extract just the broadcast_autosave_success method
    method_match = channel_source[/def broadcast_autosave_success.*?(?=\n  def |\nend)/m]
    assert method_match, "broadcast_autosave_success method should exist"

    # The workflow_saved broadcast should NOT include the full steps payload
    # Clients already have the steps — they only need confirmation + version
    refute_match(/\bsteps: workflow\.steps\b/, method_match,
      "Autosave success broadcast should not send full steps array to all subscribers")
  end

  test "step_update broadcast sends only the changed step by UUID, not all steps" do
    channel_source = File.read(Rails.root.join("app/channels/workflow_channel.rb"))

    assert_match(/step_update/, channel_source)
    assert_match(/step_uuid/, channel_source,
      "step_update should broadcast individual step UUID")
    assert_match(/step_data/, channel_source,
      "step_update should broadcast individual step data")
  end
end
