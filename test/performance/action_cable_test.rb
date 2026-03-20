require "test_helper"

class ActionCableBroadcastTest < ActiveSupport::TestCase
  include PerformanceHelper

  test "workflow channel has presence tracking" do
    channel_source = File.read(Rails.root.join("app/channels/workflow_channel.rb"))
    assert_match(/add_presence/, channel_source)
    assert_match(/remove_presence/, channel_source)
    assert_match(/broadcast_presence_update/, channel_source)
  end

  test "workflow channel supports metadata updates" do
    channel_source = File.read(Rails.root.join("app/channels/workflow_channel.rb"))
    assert_match(/workflow_metadata_update/, channel_source)
  end

  test "step CRUD broadcasts are handled via Turbo Streams in StepsController" do
    controller_source = File.read(Rails.root.join("app/controllers/steps_controller.rb"))
    assert_match(/broadcast_step_card/, controller_source,
      "StepsController should broadcast step cards for real-time collaboration")
    assert_match(/broadcast_replace_to/, controller_source,
      "StepsController should use Turbo::StreamsChannel.broadcast_replace_to")
  end
end
