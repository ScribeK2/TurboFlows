require "test_helper"

class WorkflowPresenceTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "presence-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Presence Test WF", user: @user, graph_mode: true)
  end

  test "track creates a new presence record" do
    assert_difference "WorkflowPresence.count", 1 do
      WorkflowPresence.track(
        workflow_id: @workflow.id,
        user_id: @user.id,
        user_name: "Test User",
        user_email: @user.email
      )
    end

    presence = WorkflowPresence.last
    assert_equal @workflow.id, presence.workflow_id
    assert_equal @user.id, presence.user_id
    assert_equal "Test User", presence.user_name
    assert_equal @user.email, presence.user_email
    assert_in_delta Time.current, presence.last_seen_at, 2.seconds
  end

  test "track upserts existing record and updates last_seen_at" do
    WorkflowPresence.track(
      workflow_id: @workflow.id,
      user_id: @user.id,
      user_name: "Test User",
      user_email: @user.email
    )

    assert_no_difference "WorkflowPresence.count" do
      WorkflowPresence.track(
        workflow_id: @workflow.id,
        user_id: @user.id,
        user_name: "Test User",
        user_email: @user.email
      )
    end
  end

  test "untrack deletes the presence record" do
    WorkflowPresence.track(
      workflow_id: @workflow.id,
      user_id: @user.id,
      user_name: "Test User",
      user_email: @user.email
    )

    assert_difference "WorkflowPresence.count", -1 do
      WorkflowPresence.untrack(workflow_id: @workflow.id, user_id: @user.id)
    end
  end

  test "untrack on non-existent record is a no-op" do
    assert_no_difference "WorkflowPresence.count" do
      WorkflowPresence.untrack(workflow_id: @workflow.id, user_id: @user.id)
    end
  end

  test "active_users returns active users with correct structure" do
    WorkflowPresence.track(
      workflow_id: @workflow.id,
      user_id: @user.id,
      user_name: "Test User",
      user_email: @user.email
    )

    users = WorkflowPresence.active_users(@workflow.id)
    assert_equal 1, users.length
    assert_equal @user.id, users.first[:id]
    assert_equal @user.email, users.first[:email]
    assert_equal "Test User", users.first[:name]
  end

  test "active_users returns empty array for no users" do
    users = WorkflowPresence.active_users(@workflow.id)
    assert_empty users
  end

  test "active_users excludes stale records" do
    WorkflowPresence.create!(
      workflow: @workflow,
      user: @user,
      user_name: "Stale User",
      user_email: @user.email,
      last_seen_at: 1.minute.ago
    )

    users = WorkflowPresence.active_users(@workflow.id)
    assert_empty users
  end

  test "active scope filters by 30-second threshold" do
    fresh = WorkflowPresence.create!(
      workflow: @workflow,
      user: @user,
      user_name: "Fresh",
      user_email: @user.email,
      last_seen_at: Time.current
    )

    user2 = User.create!(
      email: "stale-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    WorkflowPresence.create!(
      workflow: @workflow,
      user: user2,
      user_name: "Stale",
      user_email: user2.email,
      last_seen_at: 1.minute.ago
    )

    assert_equal [fresh], WorkflowPresence.active.to_a
  end
end
