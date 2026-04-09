require "test_helper"

class WorkflowStepValidationTest < ActiveSupport::TestCase
  setup do
    Bullet.enable = false if defined?(Bullet)

    @user = User.create!(
      email: "stepval-#{SecureRandom.hex(4)}@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Step Validation WF", user: @user, status: "draft")
  end

  teardown do
    Bullet.enable = true if defined?(Bullet)
  end

  test "workflow with fewer than MAX_STEPS steps is valid" do
    3.times do |i|
      Steps::Action.create!(workflow: @workflow, title: "Step #{i}", position: i)
    end
    @workflow.reload
    assert @workflow.valid?
  end

  test "workflow exceeding MAX_STEPS is invalid" do
    max = Workflow::MAX_STEPS
    now = Time.current
    step_attrs = (0..max).map do |i|
      {
        workflow_id: @workflow.id,
        title: "Step #{i}",
        position: i,
        uuid: SecureRandom.uuid,
        type: "Steps::Action",
        action_type: "Instruction",
        created_at: now,
        updated_at: now
      }
    end
    Step.insert_all!(step_attrs)
    # insert_all! bypasses counter cache — reset it so steps.size returns the real count
    Workflow.reset_counters(@workflow.id, :steps)
    workflow = Workflow.find(@workflow.id)

    assert_operator workflow.steps_count, :>, max
    refute workflow.valid?
    assert workflow.errors[:steps].any? { |e| e.include?("cannot exceed") }
  end

  test "workflow with exactly MAX_STEPS steps is valid" do
    max = Workflow::MAX_STEPS
    now = Time.current
    step_attrs = (0...max).map do |i|
      {
        workflow_id: @workflow.id,
        title: "Step #{i}",
        position: i,
        uuid: SecureRandom.uuid,
        type: "Steps::Action",
        action_type: "Instruction",
        created_at: now,
        updated_at: now
      }
    end
    Step.insert_all!(step_attrs)
    Workflow.reset_counters(@workflow.id, :steps)
    workflow = Workflow.find(@workflow.id)

    assert_equal max, workflow.steps_count
    workflow.valid?
    refute workflow.errors[:steps].any? { |e| e.include?("cannot exceed") }
  end
end
