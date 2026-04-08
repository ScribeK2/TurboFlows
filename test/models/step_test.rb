require "test_helper"

class StepTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "test-step@example.com", password: "password123456")
    @workflow = Workflow.create!(title: "Test Workflow", user: @user)
  end

  # --- UUID ---

  test "auto-generates UUID on create" do
    step = Steps::Question.create!(workflow: @workflow, title: "Q1", position: 0)
    assert_predicate step.uuid, :present?
    assert_match(/\A[0-9a-f-]{36}\z/, step.uuid)
  end

  test "UUID is unique within a workflow" do
    step1 = Steps::Question.create!(workflow: @workflow, title: "Q1", position: 0)
    step2 = Steps::Question.new(workflow: @workflow, title: "Q2", position: 1, uuid: step1.uuid)
    assert_not step2.valid?
    assert_includes step2.errors[:uuid], "has already been taken"
  end

  test "same UUID allowed in different workflows" do
    workflow2 = Workflow.create!(title: "Other Workflow", user: @user)
    step1 = Steps::Question.create!(workflow: @workflow, title: "Q1", position: 0)
    step2 = Steps::Question.new(workflow: workflow2, title: "Q2", position: 0, uuid: step1.uuid)
    assert_predicate step2, :valid?
  end

  test "does not overwrite manually set UUID" do
    custom_uuid = SecureRandom.uuid
    step = Steps::Question.create!(workflow: @workflow, title: "Q1", position: 0, uuid: custom_uuid)
    assert_equal custom_uuid, step.uuid
  end

  # --- UUID immutability ---

  test "UUID cannot be changed after create" do
    step = Steps::Question.create!(workflow: @workflow, title: "Q1", position: 0)
    original_uuid = step.uuid
    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      step.update!(uuid: SecureRandom.uuid)
    end
    assert_equal original_uuid, step.reload.uuid, "UUID should be immutable after creation"
  end

  # --- Associations ---

  test "belongs to workflow" do
    step = Steps::Question.new(title: "Q1", position: 0)
    assert_not step.valid?
    assert_includes step.errors[:workflow], "must exist"
  end

  test "has many transitions (outgoing)" do
    step1 = Steps::Question.create!(workflow: @workflow, title: "Q1", position: 0)
    step2 = Steps::Action.create!(workflow: @workflow, title: "A1", position: 1)
    transition = Transition.create!(step: step1, target_step: step2)
    assert_includes step1.transitions, transition
  end

  test "has many incoming_transitions" do
    step1 = Steps::Question.create!(workflow: @workflow, title: "Q1", position: 0)
    step2 = Steps::Action.create!(workflow: @workflow, title: "A1", position: 1)
    transition = Transition.create!(step: step1, target_step: step2)
    assert_includes step2.incoming_transitions, transition
  end

  test "destroying step cascades to outgoing transitions" do
    step1 = Steps::Question.create!(workflow: @workflow, title: "Q1", position: 0)
    step2 = Steps::Action.create!(workflow: @workflow, title: "A1", position: 1)
    Transition.create!(step: step1, target_step: step2)
    assert_difference "Transition.count", -1 do
      step1.destroy!
    end
  end

  test "destroying step cascades to incoming transitions" do
    step1 = Steps::Question.create!(workflow: @workflow, title: "Q1", position: 0)
    step2 = Steps::Action.create!(workflow: @workflow, title: "A1", position: 1)
    Transition.create!(step: step1, target_step: step2)
    assert_difference "Transition.count", -1 do
      step2.destroy!
    end
  end

  # --- step_type ---

  test "step_type returns underscored class name" do
    assert_equal "question", Steps::Question.create!(workflow: @workflow, title: "Q", position: 0).step_type
    assert_equal "action", Steps::Action.create!(workflow: @workflow, title: "A", position: 1).step_type
    assert_equal "message", Steps::Message.create!(workflow: @workflow, title: "M", position: 2).step_type
    assert_equal "escalate", Steps::Escalate.create!(workflow: @workflow, title: "E", position: 3).step_type
    assert_equal "resolve", Steps::Resolve.create!(workflow: @workflow, title: "R", position: 4).step_type
    assert_equal "sub_flow", Steps::SubFlow.create!(workflow: @workflow, title: "S", position: 5).step_type
  end

  # --- terminal? ---

  test "step with no transitions is terminal" do
    step = Steps::Question.create!(workflow: @workflow, title: "Q", position: 0)
    assert_predicate step, :terminal?
  end

  test "step with transitions is not terminal" do
    step1 = Steps::Question.create!(workflow: @workflow, title: "Q", position: 0)
    step2 = Steps::Action.create!(workflow: @workflow, title: "A", position: 1)
    Transition.create!(step: step1, target_step: step2)
    assert_not step1.terminal?
  end

  # --- condition_summary ---

  test "condition_summary for terminal Resolve step" do
    step = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 0)
    assert_equal "Terminal", step.condition_summary
  end

  test "condition_summary shows transition target" do
    step1 = Steps::Question.create!(workflow: @workflow, title: "Q1", position: 0)
    step2 = Steps::Action.create!(workflow: @workflow, title: "A1", position: 1)
    Transition.create!(step: step1, target_step: step2)
    summary = step1.condition_summary
    assert_includes summary, "A1"
  end

  # --- default scope ---

  test "default scope orders by position" do
    step3 = Steps::Message.create!(workflow: @workflow, title: "Third", position: 2)
    step1 = Steps::Question.create!(workflow: @workflow, title: "First", position: 0)
    step2 = Steps::Action.create!(workflow: @workflow, title: "Second", position: 1)
    steps = @workflow.steps.to_a
    assert_equal [step1, step2, step3], steps
  end

  # --- reference_url protocol validation ---

  test "allows http reference_url" do
    step = Steps::Action.new(workflow: @workflow, title: "A", position: 0, reference_url: "https://kb.example.com/article")
    assert_predicate step, :valid?
  end

  test "allows tel reference_url" do
    step = Steps::Action.new(workflow: @workflow, title: "A", position: 0, reference_url: "tel:+15551234567")
    assert_predicate step, :valid?
  end

  test "allows mailto reference_url" do
    step = Steps::Action.new(workflow: @workflow, title: "A", position: 0, reference_url: "mailto:support@example.com")
    assert_predicate step, :valid?
  end

  test "allows relative path reference_url" do
    step = Steps::Action.new(workflow: @workflow, title: "A", position: 0, reference_url: "/internal/tool")
    assert_predicate step, :valid?
  end

  test "rejects javascript reference_url" do
    step = Steps::Action.new(workflow: @workflow, title: "A", position: 0, reference_url: "javascript:alert(1)")
    assert_not step.valid?
    assert_includes step.errors[:reference_url], "must use http, https, tel, or mailto protocol"
  end

  test "rejects data reference_url" do
    step = Steps::Action.new(workflow: @workflow, title: "A", position: 0, reference_url: "data:text/html,<script>alert(1)</script>")
    assert_not step.valid?
  end

  test "allows blank reference_url" do
    step = Steps::Action.new(workflow: @workflow, title: "A", position: 0, reference_url: "")
    assert_predicate step, :valid?
  end
end
