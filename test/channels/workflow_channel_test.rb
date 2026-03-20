require "test_helper"

class WorkflowChannelLogicTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "channel-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Channel WF", user: @user, graph_mode: true)
    @channel = WorkflowChannel.allocate
    @channel.define_singleton_method(:current_user) { @test_user }
    @channel.instance_variable_set(:@test_user, @user)
  end

  test "user_info returns correct structure" do
    info = @channel.send(:user_info)
    assert_equal @user.id, info[:id]
    assert_equal @user.email, info[:email]
    assert info[:name].present?
  end

  test "presence_redis_key returns expected format" do
    key = @channel.send(:presence_redis_key, @workflow)
    assert_equal "turboflows:presence:workflow:#{@workflow.id}", key
  end
end
