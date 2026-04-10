require "test_helper"

class CleanupScenariosJobTest < ActiveJob::TestCase
  test "performs without error" do
    assert_nothing_raised { CleanupScenariosJob.perform_now }
  end

  test "can be enqueued" do
    assert_enqueued_with(job: CleanupScenariosJob) do
      CleanupScenariosJob.perform_later
    end
  end
end
