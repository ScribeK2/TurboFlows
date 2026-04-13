require "test_helper"

module Steps
  class ResolveTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "test-resolve@example.com", password: "password123456")
      @workflow = Workflow.create!(title: "Resolve Test", user: @user)
    end

    test "valid with title only" do
      step = Steps::Resolve.new(workflow: @workflow, title: "Done", position: 0)
      assert_predicate step, :valid?
    end

    test "validates resolution_type against allowed values" do
      Steps::Resolve::VALID_RESOLUTION_TYPES.each do |rt|
        step = Steps::Resolve.new(workflow: @workflow, title: "R", position: 0, resolution_type: rt)
        assert_predicate step, :valid?, "Expected resolution_type '#{rt}' to be valid"
      end
    end

    test "rejects invalid resolution_type" do
      step = Steps::Resolve.new(workflow: @workflow, title: "R", position: 0, resolution_type: "invalid")
      assert_not step.valid?
      assert_includes step.errors[:resolution_type], "is not included in the list"
    end

    test "always terminal regardless of transitions" do
      step1 = Steps::Resolve.create!(workflow: @workflow, title: "Resolve", position: 0)
      step2 = Steps::Question.create!(workflow: @workflow, title: "Q", position: 1)
      Transition.create!(step: step1, target_step: step2)
      assert_predicate step1, :terminal?, "Resolve step should always be terminal"
    end

    test "outcome_summary includes resolution_type" do
      step = Steps::Resolve.create!(workflow: @workflow, title: "R1", position: 0, resolution_type: "success")
      summary = step.outcome_summary
      assert_includes summary, "Success"
    end

    test "step_type returns resolve" do
      step = Steps::Resolve.create!(workflow: @workflow, title: "R1", position: 0)
      assert_equal "resolve", step.step_type
    end

    test "rejects removed resolution_type 'transferred'" do
      step = Steps::Resolve.new(workflow: @workflow, title: "R", position: 0, resolution_type: "transferred")
      assert_not step.valid?
      assert_includes step.errors[:resolution_type], "is not included in the list"
    end

    test "rejects removed resolution_type 'other'" do
      step = Steps::Resolve.new(workflow: @workflow, title: "R", position: 0, resolution_type: "other")
      assert_not step.valid?
      assert_includes step.errors[:resolution_type], "is not included in the list"
    end

    test "accepts new resolution_type values" do
      %w[failure cancelled escalated].each do |rt|
        step = Steps::Resolve.new(workflow: @workflow, title: "R", position: 0, resolution_type: rt)
        assert_predicate step, :valid?, "Expected resolution_type '#{rt}' to be valid"
      end
    end
  end
end
