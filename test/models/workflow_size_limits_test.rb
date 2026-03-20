require "test_helper"

class WorkflowSizeLimitsTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(
      email: "test@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
  end

  test "workflow with valid step count is accepted" do
    workflow = Workflow.create!(title: "Normal Workflow", user: @user, status: :draft)

    10.times do |i|
      Steps::Question.create!(
        workflow: workflow,
        uuid: SecureRandom.uuid,
        position: i,
        title: "Step #{i}",
        question: "Q?"
      )
    end

    assert_predicate workflow, :valid?, "Workflow should be valid: #{workflow.errors.full_messages.join(', ')}"
  end

  test "workflow exceeding MAX_STEPS is rejected" do
    workflow = Workflow.create!(title: "Too Many Steps", user: @user)

    (Workflow::MAX_STEPS + 1).times do |i|
      step = Steps::Action.new(
        workflow: workflow,
        uuid: SecureRandom.uuid,
        position: i,
        title: "Step #{i}"
      )
      step.save!(validate: false)
    end

    # Reload to pick up the association
    workflow.reload
    assert_not workflow.valid?
    assert(workflow.errors[:steps].any? { |e| e.include?("cannot exceed") })
  end

  test "workflow title exceeding 255 characters is rejected" do
    long_title = "A" * 256

    workflow = Workflow.new(
      title: long_title,
      user: @user
    )

    assert_not workflow.valid?
    assert_predicate workflow.errors[:title], :any?
  end

  test "constants are accessible and reasonable" do
    assert_operator Workflow::MAX_STEPS, :>=, 100, "MAX_STEPS should allow at least 100 steps"
    assert_operator Workflow::MAX_STEPS, :<=, 500, "MAX_STEPS should not exceed 500"
  end
end
