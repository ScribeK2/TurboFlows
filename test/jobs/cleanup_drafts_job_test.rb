require "test_helper"

class CleanupDraftsJobTest < ActiveJob::TestCase
  test "performs without error" do
    assert_nothing_raised { CleanupDraftsJob.perform_now }
  end

  test "can be enqueued" do
    assert_enqueued_with(job: CleanupDraftsJob) do
      CleanupDraftsJob.perform_later
    end
  end
end
