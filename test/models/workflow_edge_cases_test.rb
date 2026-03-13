require "test_helper"

class WorkflowEdgeCasesTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(
      email: "edge-cases-test@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
  end

  # ==========================================================================
  # Scenario 4: Edge Cases - Duplicate Variable Names
  # ==========================================================================

  test "duplicate variable_name overwrites previous value in scenario" do
    workflow = Workflow.create!(title: "Duplicate Variable Workflow", user: @user)
    Steps::Question.create!(workflow: workflow, position: 0, uuid: "step-1", title: "First Question", question: "First answer?", variable_name: "shared_var")
    Steps::Question.create!(workflow: workflow, position: 1, uuid: "step-2", title: "Second Question", question: "Second answer?", variable_name: "shared_var")
    Steps::Action.create!(workflow: workflow, position: 2, uuid: "step-3", title: "Result")

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: "active",
      current_step_index: 0,
      results: {},
      inputs: {}
    )

    # Answer first question
    scenario.process_step("first_answer")

    # Answer second question with same variable name
    scenario.process_step("second_answer")

    # The second answer should overwrite the first
    assert_equal "second_answer", scenario.results["shared_var"]
  end

  # ==========================================================================
  # Scenario 4: Edge Cases - Empty Workflow
  # ==========================================================================

  test "workflow can be created without steps" do
    workflow = Workflow.new(
      title: "Empty Workflow",
      user: @user,
      steps: []
    )

    assert_predicate workflow, :valid?
    assert workflow.save
    assert_empty workflow.steps
  end

  test "workflow can be created with nil steps" do
    workflow = Workflow.new(
      title: "Nil Steps Workflow",
      user: @user,
      steps: nil
    )

    assert_predicate workflow, :valid?
    assert workflow.save
  end

  # ==========================================================================
  # Scenario 4: Edge Cases - Max Steps Limit
  # ==========================================================================

  test "workflow accepts max steps (200)" do
    steps = (1..200).map do |i|
      {
        "id" => "step-#{i}",
        "type" => "action",
        "title" => "Step #{i}",
        "instructions" => "Do step #{i}"
      }
    end

    workflow = Workflow.new(
      title: "Max Steps Workflow",
      user: @user,
      steps: steps
    )

    assert_predicate workflow, :valid?, "Expected workflow with 200 steps to be valid, got errors: #{workflow.errors.full_messages}"
    assert workflow.save
    assert_equal 200, workflow.steps.length
  end

  test "workflow rejects exceeding max steps (201)" do
    steps = (1..201).map do |i|
      {
        "id" => "step-#{i}",
        "type" => "action",
        "title" => "Step #{i}",
        "instructions" => "Do step #{i}"
      }
    end

    workflow = Workflow.new(
      title: "Too Many Steps Workflow",
      user: @user,
      steps: steps
    )

    assert_not workflow.valid?
    assert(workflow.errors[:steps].any? { |e| e.include?("cannot exceed") || e.include?("200") })
  end

  # ==========================================================================
  # Scenario 4: Edge Cases - Missing Title
  # ==========================================================================

  test "step without title fails validation" do
    workflow = Workflow.new(
      title: "Missing Step Title Workflow",
      user: @user,
      steps: [
        {
          "id" => "step-1",
          "type" => "question",
          "question" => "What is your name?"
          # Missing 'title'
        }
      ]
    )

    assert_not workflow.valid?
    assert(workflow.errors[:steps].any? { |e| e.include?("Title is required") })
  end

  test "step with blank title fails validation" do
    workflow = Workflow.new(
      title: "Blank Step Title Workflow",
      user: @user,
      steps: [
        {
          "id" => "step-1",
          "type" => "question",
          "title" => "",
          "question" => "What is your name?"
        }
      ]
    )

    assert_not workflow.valid?
    assert(workflow.errors[:steps].any? { |e| e.include?("Title is required") })
  end

  # ==========================================================================
  # Scenario 5: Error Conditions - Stopped Scenario
  # ==========================================================================

  test "process_step returns false on stopped scenario" do
    workflow = Workflow.create!(
      title: "Stopped Workflow",
      user: @user,
      steps: [
        {
          "id" => "step-1",
          "type" => "question",
          "title" => "Question",
          "question" => "Answer?"
        }
      ]
    )

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: 'stopped',
      current_step_index: 0,
      results: {},
      inputs: {}
    )

    result = scenario.process_step("answer")

    assert_equal false, result
    # Should not have processed the step
    assert_nil scenario.results["Question"]
  end

  test "process_step returns false on error status scenario" do
    workflow = Workflow.create!(
      title: "Error Workflow",
      user: @user,
      steps: [
        {
          "id" => "step-1",
          "type" => "question",
          "title" => "Question",
          "question" => "Answer?"
        }
      ]
    )

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: 'error',
      current_step_index: 0,
      results: {},
      inputs: {}
    )

    result = scenario.process_step("answer")

    assert_equal false, result
  end

  test "process_step returns false on timeout status scenario" do
    workflow = Workflow.create!(
      title: "Timeout Workflow",
      user: @user,
      steps: [
        {
          "id" => "step-1",
          "type" => "question",
          "title" => "Question",
          "question" => "Answer?"
        }
      ]
    )

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: 'timeout',
      current_step_index: 0,
      results: {},
      inputs: {}
    )

    result = scenario.process_step("answer")

    assert_equal false, result
  end

  # ==========================================================================
  # Step UUID Auto-Assignment Tests (AR Step model)
  # ==========================================================================

  test "AR steps without UUIDs get assigned UUIDs on save" do
    workflow = Workflow.create!(title: "No UUID Workflow", user: @user)

    q_step = Steps::Question.create!(workflow: workflow, position: 0, title: "Question", question: "What?")
    a_step = Steps::Action.create!(workflow: workflow, position: 1, title: "Action")

    [q_step, a_step].each do |step|
      assert_predicate step.uuid, :present?, "Step #{step.title} should have a UUID"
      assert_match(/^[0-9a-f-]{36}$/, step.uuid, "Step UUID should be a UUID format")
    end
  end

  test "AR steps with explicit UUIDs preserve them on save" do
    workflow = Workflow.create!(title: "Existing UUID Workflow", user: @user)
    existing_uuid = "my-custom-id-12345"

    step = Steps::Action.create!(workflow: workflow, position: 0, uuid: existing_uuid, title: "Action")

    assert_equal existing_uuid, step.uuid
  end

  # ==========================================================================
  # AR Step Validation Tests
  # ==========================================================================

  test "question step requires question text" do
    workflow = Workflow.create!(title: "Missing Question Workflow", user: @user)

    step = Steps::Question.new(workflow: workflow, position: 0, title: "Question Step")
    assert_not step.valid?
    assert_includes step.errors[:question], "can't be blank"
  end

  # ==========================================================================
  # Auto-Generate Variable Names Tests (AR Steps::Question)
  # ==========================================================================

  test "auto-generates variable_name from title for question steps" do
    workflow = Workflow.create!(title: "Auto Variable Test", user: @user)

    step = Steps::Question.create!(workflow: workflow, position: 0, title: "Customer Name", question: "What is your name?")

    assert_equal "customer_name", step.variable_name
  end

  test "auto-generates variable_name handles punctuation" do
    workflow = Workflow.create!(title: "Punctuation Test", user: @user)

    step = Steps::Question.create!(workflow: workflow, position: 0, title: "What is your issue?", question: "Describe the problem")

    assert_equal "what_is_your_issue", step.variable_name
  end

  test "preserves explicit variable_name if provided" do
    workflow = Workflow.create!(title: "Explicit Variable Test", user: @user)

    step = Steps::Question.create!(workflow: workflow, position: 0, title: "Customer Name", question: "What is your name?", variable_name: "my_custom_var")

    assert_equal "my_custom_var", step.variable_name
  end

  test "does not generate variable_name for non-question steps" do
    workflow = Workflow.create!(title: "Non-Question Test", user: @user)

    step = Steps::Action.create!(workflow: workflow, position: 0, title: "Some Action")

    assert_nil step.variable_name
  end

  test "generate_variable_name limits length to 30 characters" do
    workflow = Workflow.new(title: "Test", user: @user)
    long_title = "This Is A Very Long Title That Should Be Truncated"

    result = workflow.generate_variable_name(long_title)

    assert_operator result.length, :<=, 30
    assert_not result.end_with?("_")
  end

  # ==========================================================================
  # Variables Extraction Tests (AR Steps)
  # ==========================================================================

  test "variables method extracts all variable names from questions" do
    workflow = Workflow.create!(title: "Variables Workflow", user: @user)

    Steps::Question.create!(workflow: workflow, position: 0, title: "Q1", question: "Name?", variable_name: "customer_name")
    Steps::Question.create!(workflow: workflow, position: 1, title: "Q2", question: "Issue?", variable_name: "issue_type")
    Steps::Action.create!(workflow: workflow, position: 2, title: "Action")

    variables = workflow.variables

    assert_includes variables, "customer_name"
    assert_includes variables, "issue_type"
    assert_equal 2, variables.length
  end

  test "variables method includes output_fields from action steps" do
    workflow = Workflow.create!(title: "Output Fields Workflow", user: @user)

    Steps::Question.create!(workflow: workflow, position: 0, title: "Q1", question: "Name?", variable_name: "name")
    Steps::Action.create!(
      workflow: workflow, position: 1, title: "Action",
      output_fields: [
        { "name" => "status", "value" => "done" },
        { "name" => "timestamp", "value" => "now" }
      ]
    )

    variables = workflow.variables

    assert_includes variables, "name"
    assert_includes variables, "status"
    assert_includes variables, "timestamp"
  end
end
