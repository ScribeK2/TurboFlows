require "test_helper"

module Steps
  class ActionTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "test-action@example.com", password: "password123456")
      @workflow = Workflow.create!(title: "Action Test", user: @user)
    end

    test "valid with title only" do
      step = Steps::Action.new(workflow: @workflow, title: "Do something", position: 0)
      assert_predicate step, :valid?
    end

    test "has rich text instructions" do
      step = Steps::Action.create!(workflow: @workflow, title: "A1", position: 0)
      step.instructions = "<p>Follow these steps carefully</p>"
      step.save!
      assert_equal "Follow these steps carefully", step.instructions.to_plain_text
    end

    test "outcome_summary includes action_type and truncated instructions" do
      step = Steps::Action.create!(workflow: @workflow, title: "A1", action_type: "manual", position: 0)
      step.instructions = "Do this specific thing for the customer"
      step.save!
      summary = step.outcome_summary
      assert_includes summary, "manual"
    end

    test "outcome_summary without instructions" do
      step = Steps::Action.create!(workflow: @workflow, title: "A1", action_type: "manual", position: 0)
      summary = step.outcome_summary
      assert_includes summary, "manual"
    end

    test "step_type returns action" do
      step = Steps::Action.create!(workflow: @workflow, title: "A1", position: 0)
      assert_equal "action", step.step_type
    end
  end
end
