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
    workflow = Workflow.create!(
      title: "Duplicate Variable Workflow",
      user: @user,
      steps: [
        {
          "id" => "step-1",
          "type" => "question",
          "title" => "First Question",
          "question" => "First answer?",
          "variable_name" => "shared_var"
        },
        {
          "id" => "step-2",
          "type" => "question",
          "title" => "Second Question",
          "question" => "Second answer?",
          "variable_name" => "shared_var"
        },
        {
          "id" => "step-3",
          "type" => "action",
          "title" => "Result",
          "instructions" => "Done"
        }
      ]
    )

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: 'active',
      current_step_index: 0,
      results: {},
      inputs: {}
    )

    # Answer first question
    scenario.process_step("first_value")

    assert_equal "first_value", scenario.results["shared_var"]

    # Answer second question with same variable_name
    scenario.process_step("second_value")

    # Second value should overwrite first
    assert_equal "second_value", scenario.results["shared_var"]
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
  # Step ID Auto-Assignment Tests
  # ==========================================================================

  test "steps without IDs get assigned UUIDs on save" do
    workflow = Workflow.create!(
      title: "No ID Workflow",
      user: @user,
      steps: [
        {
          "type" => "question",
          "title" => "Question",
          "question" => "What?"
        },
        {
          "type" => "action",
          "title" => "Action",
          "instructions" => "Do"
        }
      ]
    )

    # All steps should have IDs now
    workflow.steps.each do |step|
      assert_predicate step["id"], :present?, "Step #{step['title']} should have an ID"
      assert_match(/^[0-9a-f-]{36}$/, step["id"], "Step ID should be a UUID format")
    end
  end

  test "existing step IDs are preserved on save" do
    existing_id = "my-custom-id-12345"
    workflow = Workflow.create!(
      title: "Existing ID Workflow",
      user: @user,
      steps: [
        {
          "id" => existing_id,
          "type" => "action",
          "title" => "Action",
          "instructions" => "Do"
        }
      ]
    )

    assert_equal existing_id, workflow.steps.first["id"]
  end

  # ==========================================================================
  # Step Type Validation Tests
  # ==========================================================================

  test "invalid step type fails validation" do
    workflow = Workflow.new(
      title: "Invalid Type Workflow",
      user: @user,
      steps: [
        {
          "id" => "step-1",
          "type" => "invalid_type",
          "title" => "Bad Step"
        }
      ]
    )

    assert_not workflow.valid?
    assert(workflow.errors[:steps].any? { |e| e.include?("Invalid step type") })
  end

  test "question step requires question text" do
    workflow = Workflow.new(
      title: "Missing Question Workflow",
      user: @user,
      steps: [
        {
          "id" => "step-1",
          "type" => "question",
          "title" => "Question Step"
          # Missing 'question' field
        }
      ]
    )

    assert_not workflow.valid?
    assert(workflow.errors[:steps].any? { |e| e.include?("Question text is required") })
  end

  # ==========================================================================
  # Size Limit Tests
  # ==========================================================================

  test "step title exceeding max length fails validation" do
    long_title = "A" * 501 # Max is 500

    workflow = Workflow.new(
      title: "Long Title Workflow",
      user: @user,
      steps: [
        {
          "id" => "step-1",
          "type" => "action",
          "title" => long_title,
          "instructions" => "Do"
        }
      ]
    )

    assert_not workflow.valid?
    assert(workflow.errors[:steps].any? { |e| e.include?("Title is too long") })
  end

  # ==========================================================================
  # Auto-Generate Variable Names Tests
  # ==========================================================================

  test "auto-generates variable_name from title for question steps" do
    workflow = Workflow.create!(
      title: "Auto Variable Test",
      user: @user,
      steps: [
        {
          "type" => "question",
          "title" => "Customer Name",
          "question" => "What is your name?"
          # No variable_name provided
        }
      ]
    )

    question_step = workflow.steps.first

    assert_equal "customer_name", question_step["variable_name"]
  end

  test "auto-generates variable_name handles punctuation" do
    workflow = Workflow.create!(
      title: "Punctuation Test",
      user: @user,
      steps: [
        {
          "type" => "question",
          "title" => "What is your issue?",
          "question" => "Describe the problem"
        }
      ]
    )

    question_step = workflow.steps.first

    assert_equal "what_is_your_issue", question_step["variable_name"]
  end

  test "auto-generated variable names are unique" do
    workflow = Workflow.create!(
      title: "Unique Variable Test",
      user: @user,
      steps: [
        {
          "type" => "question",
          "title" => "Customer Name",
          "question" => "First name?"
        },
        {
          "type" => "question",
          "title" => "Customer Name",
          "question" => "Last name?"
        }
      ]
    )

    first_step = workflow.steps[0]
    second_step = workflow.steps[1]

    assert_equal "customer_name", first_step["variable_name"]
    assert_equal "customer_name_2", second_step["variable_name"]
  end

  test "preserves explicit variable_name if provided" do
    workflow = Workflow.create!(
      title: "Explicit Variable Test",
      user: @user,
      steps: [
        {
          "type" => "question",
          "title" => "Customer Name",
          "question" => "What is your name?",
          "variable_name" => "my_custom_var"
        }
      ]
    )

    question_step = workflow.steps.first

    assert_equal "my_custom_var", question_step["variable_name"]
  end

  test "does not generate variable_name for non-question steps" do
    workflow = Workflow.create!(
      title: "Non-Question Test",
      user: @user,
      steps: [
        {
          "type" => "action",
          "title" => "Some Action",
          "instructions" => "Do something"
        }
      ]
    )

    action_step = workflow.steps.first

    assert_nil action_step["variable_name"]
  end

  test "generate_variable_name limits length to 30 characters" do
    workflow = Workflow.new(title: "Test", user: @user)
    long_title = "This Is A Very Long Title That Should Be Truncated"

    result = workflow.generate_variable_name(long_title)

    assert_operator result.length, :<=, 30
    assert_not result.end_with?("_")
  end

  # ==========================================================================
  # Variables Extraction Tests
  # ==========================================================================

  test "variables method extracts all variable names from questions" do
    workflow = Workflow.create!(
      title: "Variables Workflow",
      user: @user,
      steps: [
        {
          "id" => "step-1",
          "type" => "question",
          "title" => "Q1",
          "question" => "Name?",
          "variable_name" => "customer_name"
        },
        {
          "id" => "step-2",
          "type" => "question",
          "title" => "Q2",
          "question" => "Issue?",
          "variable_name" => "issue_type"
        },
        {
          "id" => "step-3",
          "type" => "action",
          "title" => "Action",
          "instructions" => "Do"
        }
      ]
    )

    variables = workflow.variables

    assert_includes variables, "customer_name"
    assert_includes variables, "issue_type"
    assert_equal 2, variables.length
  end

  test "variables method includes output_fields from action steps" do
    workflow = Workflow.create!(
      title: "Output Fields Workflow",
      user: @user,
      steps: [
        {
          "id" => "step-1",
          "type" => "question",
          "title" => "Q1",
          "question" => "Name?",
          "variable_name" => "name"
        },
        {
          "id" => "step-2",
          "type" => "action",
          "title" => "Action",
          "instructions" => "Do",
          "output_fields" => [
            { "name" => "status", "value" => "done" },
            { "name" => "timestamp", "value" => "now" }
          ]
        }
      ]
    )

    variables = workflow.variables

    assert_includes variables, "name"
    assert_includes variables, "status"
    assert_includes variables, "timestamp"
  end
end
