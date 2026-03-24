require "test_helper"

module Steps
  class EscalateTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "test-escalate@example.com", password: "password123456")
      @workflow = Workflow.create!(title: "Escalate Test", user: @user)
    end

    test "valid with title only" do
      step = Steps::Escalate.new(workflow: @workflow, title: "Escalate", position: 0)
      assert_predicate step, :valid?
    end

    test "validates target_type against allowed values" do
      Steps::Escalate::VALID_TARGET_TYPES.each do |target_type|
        step = Steps::Escalate.new(workflow: @workflow, title: "E", position: 0, target_type: target_type)
        assert_predicate step, :valid?, "Expected target_type '#{target_type}' to be valid"
      end
    end

    test "rejects invalid target_type" do
      step = Steps::Escalate.new(workflow: @workflow, title: "E", position: 0, target_type: "invalid")
      assert_not step.valid?
      assert_includes step.errors[:target_type], "is not included in the list"
    end

    test "validates priority against allowed values" do
      Steps::Escalate::VALID_PRIORITIES.each do |priority|
        step = Steps::Escalate.new(workflow: @workflow, title: "E", position: 0, priority: priority)
        assert_predicate step, :valid?, "Expected priority '#{priority}' to be valid"
      end
    end

    test "rejects invalid priority" do
      step = Steps::Escalate.new(workflow: @workflow, title: "E", position: 0, priority: "invalid")
      assert_not step.valid?
      assert_includes step.errors[:priority], "is not included in the list"
    end

    test "has rich text notes" do
      step = Steps::Escalate.create!(workflow: @workflow, title: "E1", position: 0)
      step.notes = "<p>Urgent customer issue</p>"
      step.save!
      assert_equal "Urgent customer issue", step.notes.to_plain_text
    end

    test "is NOT always terminal (can have outgoing transitions)" do
      step1 = Steps::Escalate.create!(workflow: @workflow, title: "Escalate", position: 0)
      step2 = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 1)
      Transition.create!(step: step1, target_step: step2)
      assert_not step1.terminal?
    end

    test "outcome_summary includes priority and target" do
      step = Steps::Escalate.create!(workflow: @workflow, title: "E1", position: 0, target_type: "supervisor", target_value: "John", priority: "high")
      summary = step.outcome_summary
      assert_includes summary, "High"
      assert_includes summary, "supervisor"
      assert_includes summary, "John"
    end

    test "step_type returns escalate" do
      step = Steps::Escalate.create!(workflow: @workflow, title: "E1", position: 0)
      assert_equal "escalate", step.step_type
    end
  end
end
