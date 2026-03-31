require "test_helper"

class CleanupStalePresencesJobTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "cleanup-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Cleanup Test WF", user: @user, graph_mode: true)
  end

  test "deletes stale records and keeps recent ones" do
    # Stale record (6 minutes old)
    WorkflowPresence.create!(
      workflow: @workflow,
      user: @user,
      user_name: "Stale",
      user_email: @user.email,
      last_seen_at: 6.minutes.ago
    )

    # Fresh record
    user2 = User.create!(
      email: "cleanup2-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    WorkflowPresence.create!(
      workflow: @workflow,
      user: user2,
      user_name: "Fresh",
      user_email: user2.email,
      last_seen_at: Time.current
    )

    assert_equal 2, WorkflowPresence.count

    CleanupStalePresencesJob.perform_now

    assert_equal 1, WorkflowPresence.count
    assert_equal user2.id, WorkflowPresence.first.user_id
  end
end
