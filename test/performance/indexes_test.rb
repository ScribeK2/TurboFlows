require "test_helper"

class IndexesTest < ActiveSupport::TestCase
  include PerformanceHelper

  setup do
    @data = seed_performance_data
  end

  test "workflow list sorted by updated_at is efficient with 200 rows" do
    assert_completes_within(0.5) do
      Workflow.order(updated_at: :desc).limit(20).to_a
    end
  end

  test "workflow search by title is efficient with 200 rows" do
    assert_completes_within(1.0) do
      Workflow.where("title LIKE ?", "%Performance Test Workflow 5%").to_a
    end
  end

  test "steps_count column exists and is accurate" do
    workflow = @data[:workflows].first
    expected = workflow.workflow_steps.count
    assert_equal expected, workflow.steps_count,
      "steps_count should match actual AR steps count"
  end

  test "sorting by steps_count uses cached column instead of json function" do
    assert_completes_within(0.5) do
      Workflow.order(steps_count: :desc).limit(20).to_a
    end
  end
end
