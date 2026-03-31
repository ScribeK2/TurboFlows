require "test_helper"

class WorkflowChannelTest < ActiveSupport::TestCase
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
    @channel.define_singleton_method(:params) { { workflow_id: @test_workflow.id } }
    @channel.instance_variable_set(:@test_workflow, @workflow)
  end

  test "user_info returns correct structure" do
    info = @channel.send(:user_info)
    assert_equal @user.id, info[:id]
    assert_equal @user.email, info[:email]
    assert_predicate info[:name], :present?
  end

  test "find_workflow returns the workflow from params" do
    workflow = @channel.send(:find_workflow)
    assert_equal @workflow, workflow
  end
end

class WorkflowPresenceIntegrationTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "presence-int-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Presence Integration WF", user: @user, graph_mode: true)
  end

  test "track and untrack cycle works end-to-end" do
    WorkflowPresence.track(
      workflow_id: @workflow.id,
      user_id: @user.id,
      user_name: "Test",
      user_email: @user.email
    )

    users = WorkflowPresence.active_users(@workflow.id)
    assert_equal 1, users.length

    WorkflowPresence.untrack(workflow_id: @workflow.id, user_id: @user.id)

    users = WorkflowPresence.active_users(@workflow.id)
    assert_empty users
  end

  test "multiple users on same workflow appear in active_users" do
    user2 = User.create!(
      email: "presence-int2-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )

    WorkflowPresence.track(
      workflow_id: @workflow.id,
      user_id: @user.id,
      user_name: "User 1",
      user_email: @user.email
    )
    WorkflowPresence.track(
      workflow_id: @workflow.id,
      user_id: user2.id,
      user_name: "User 2",
      user_email: user2.email
    )

    users = WorkflowPresence.active_users(@workflow.id)
    assert_equal 2, users.length
    assert_includes users.map { |u| u[:id] }, @user.id
    assert_includes users.map { |u| u[:id] }, user2.id
  end
end
