require "test_helper"

class CleanupDraftsJobTest < ActiveJob::TestCase
  def setup
    @user = User.create!(
      email: "cleanup-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
  end

  test "performs without error" do
    assert_nothing_raised { CleanupDraftsJob.perform_now }
  end

  test "can be enqueued" do
    assert_enqueued_with(job: CleanupDraftsJob) do
      CleanupDraftsJob.perform_later
    end
  end

  test "cleans up expired drafts" do
    expired = Workflow.create!(title: "Expired Draft", user: @user, status: "draft")
    expired.update_columns(draft_expires_at: 1.day.ago)

    assert_difference("Workflow.count", -1) do
      CleanupDraftsJob.perform_now
    end

    assert_not Workflow.exists?(expired.id)
  end

  test "cleans up orphaned drafts" do
    orphan = Workflow.create!(title: "Untitled Workflow", user: @user, status: "draft")
    orphan.update_column(:created_at, 2.days.ago)

    assert_difference("Workflow.count", -1) do
      CleanupDraftsJob.perform_now
    end

    assert_not Workflow.exists?(orphan.id)
  end

  test "cleans up both expired and orphaned drafts in single run" do
    expired = Workflow.create!(title: "Expired Draft", user: @user, status: "draft")
    expired.update_columns(draft_expires_at: 1.day.ago)

    orphan = Workflow.create!(title: "Untitled Workflow", user: @user, status: "draft")
    orphan.update_column(:created_at, 2.days.ago)

    assert_difference("Workflow.count", -2) do
      CleanupDraftsJob.perform_now
    end
  end
end
