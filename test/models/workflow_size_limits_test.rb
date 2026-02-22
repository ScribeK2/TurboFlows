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
    workflow = Workflow.new(
      title: "Normal Workflow",
      user: @user,
      steps: 10.times.map { |i| { "type" => "question", "title" => "Step #{i}", "question" => "Q?" } }
    )

    assert_predicate workflow, :valid?, "Workflow should be valid: #{workflow.errors.full_messages.join(', ')}"
  end

  test "workflow exceeding MAX_STEPS is rejected" do
    # Create workflow with more than MAX_STEPS
    too_many_steps = (Workflow::MAX_STEPS + 1).times.map do |i|
      { "type" => "question", "title" => "Step #{i}", "question" => "Question #{i}?" }
    end

    workflow = Workflow.new(
      title: "Too Many Steps",
      user: @user,
      steps: too_many_steps
    )

    assert_not workflow.valid?
    assert(workflow.errors[:steps].any? { |e| e.include?("cannot exceed") })
  end

  test "step with title exceeding MAX_STEP_TITLE_LENGTH is rejected" do
    long_title = "A" * (Workflow::MAX_STEP_TITLE_LENGTH + 1)

    workflow = Workflow.new(
      title: "Long Title Step",
      user: @user,
      steps: [{ "type" => "question", "title" => long_title, "question" => "Q?" }]
    )

    assert_not workflow.valid?
    assert(workflow.errors[:steps].any? { |e| e.include?("Title is too long") })
  end

  test "step with content exceeding MAX_STEP_CONTENT_LENGTH is rejected" do
    # Create content larger than 50KB
    large_content = "A" * (Workflow::MAX_STEP_CONTENT_LENGTH + 1)

    workflow = Workflow.new(
      title: "Large Content Step",
      user: @user,
      steps: [{ "type" => "action", "title" => "Step 1", "instructions" => large_content }]
    )

    assert_not workflow.valid?
    assert(workflow.errors[:steps].any? { |e| e.include?("too large") })
  end

  test "step with too many options is rejected" do
    many_options = 101.times.map { |i| { "label" => "Option #{i}", "value" => "opt_#{i}" } }

    workflow = Workflow.new(
      title: "Too Many Options",
      user: @user,
      steps: [{
        "type" => "question",
        "title" => "Step 1",
        "question" => "Choose one?",
        "answer_type" => "multiple_choice",
        "options" => many_options
      }]
    )

    assert_not workflow.valid?
    assert(workflow.errors[:steps].any? { |e| e.include?("Too many options") })
  end

  test "step with too many branches is rejected" do
    many_branches = 51.times.map { |i| { "condition" => "var == '#{i}'", "path" => "Step #{i}" } }

    workflow = Workflow.new(
      title: "Too Many Branches",
      user: @user,
      steps: [{
        "type" => "question",
        "title" => "Step 1",
        "branches" => many_branches
      }]
    )

    assert_not workflow.valid?
    assert(workflow.errors[:steps].any? { |e| e.include?("Too many branches") })
  end

  test "workflow title exceeding 255 characters is rejected" do
    long_title = "A" * 256

    workflow = Workflow.new(
      title: long_title,
      user: @user,
      steps: []
    )

    assert_not workflow.valid?
    assert_predicate workflow.errors[:title], :any?
  end

  test "valid workflow with moderate content passes all limits" do
    workflow = Workflow.new(
      title: "Moderate Workflow",
      user: @user,
      steps: [
        {
          "type" => "question",
          "title" => "Question Step",
          "question" => "What is your name?",
          "answer_type" => "text",
          "variable_name" => "name"
        },
        {
          "type" => "question",
          "title" => "Decision Step",
          "branches" => [
            { "condition" => "name == 'test'", "path" => "Action Step" }
          ],
          "else_path" => "Question Step"
        },
        {
          "type" => "action",
          "title" => "Action Step",
          "instructions" => "This is a moderate-length instruction that should pass validation."
        }
      ]
    )

    assert_predicate workflow, :valid?, "Workflow should be valid: #{workflow.errors.full_messages.join(', ')}"
  end

  test "constants are accessible and reasonable" do
    assert_operator Workflow::MAX_STEPS, :>=, 100, "MAX_STEPS should allow at least 100 steps"
    assert_operator Workflow::MAX_STEPS, :<=, 500, "MAX_STEPS should not exceed 500"

    assert_operator Workflow::MAX_STEP_TITLE_LENGTH, :>=, 200, "Title limit should allow reasonable titles"
    assert_operator Workflow::MAX_STEP_CONTENT_LENGTH, :>=, 10_000, "Content limit should allow detailed instructions"
    assert_operator Workflow::MAX_TOTAL_STEPS_SIZE, :>=, 1_000_000, "Total size should allow at least 1MB"
  end
end
