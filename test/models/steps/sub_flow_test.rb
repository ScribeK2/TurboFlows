require "test_helper"

module Steps
  class SubFlowTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "test-subflow@example.com", password: "password123456")
      @workflow = Workflow.create!(title: "SubFlow Test", user: @user)
      @target_workflow = Workflow.create!(title: "Target Flow", user: @user, status: "published")
    end

    test "valid with title only (draft mode)" do
      step = Steps::SubFlow.new(workflow: @workflow, title: "Run sub", position: 0)
      assert_predicate step, :valid?
    end

    test "belongs to target_workflow" do
      step = Steps::SubFlow.create!(workflow: @workflow, title: "Sub", position: 0, sub_flow_workflow_id: @target_workflow.id)
      assert_equal @target_workflow, step.target_workflow
    end

    test "outcome_summary includes target workflow title" do
      step = Steps::SubFlow.create!(workflow: @workflow, title: "Sub", position: 0, sub_flow_workflow_id: @target_workflow.id)
      summary = step.outcome_summary
      assert_includes summary, "Target Flow"
    end

    test "outcome_summary without target workflow" do
      step = Steps::SubFlow.create!(workflow: @workflow, title: "Sub", position: 0)
      summary = step.outcome_summary
      assert_kind_of String, summary
    end

    test "step_type returns sub_flow" do
      step = Steps::SubFlow.create!(workflow: @workflow, title: "Sub", position: 0)
      assert_equal "sub_flow", step.step_type
    end
  end
end
