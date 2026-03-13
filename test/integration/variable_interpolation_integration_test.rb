require "test_helper"

class VariableInterpolationIntegrationTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(
      email: "test@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    sign_in @user

    # Create workflow with AR steps for interpolation testing
    @workflow = Workflow.create!(
      title: "Interpolation Test Workflow",
      description: "Testing variable interpolation",
      user: @user,
      is_public: false
    )
    Steps::Question.create!(workflow: @workflow, position: 0, uuid: "q1", title: "Name Question", question: "What is your name?", variable_name: "customer_name", answer_type: "text")
    Steps::Question.create!(workflow: @workflow, position: 1, uuid: "q2", title: "Interpolated Question", question: "Hello {{customer_name}}, what is your issue?", variable_name: "issue", answer_type: "text")
    Steps::Action.create!(workflow: @workflow, position: 2, uuid: "a1", title: "Interpolated Action", action_type: "Notification")
    Steps::Action.create!(workflow: @workflow, position: 3, uuid: "a2", title: "Action with Output Fields", action_type: "Status Update", output_fields: [
      { "name" => "status", "value" => "resolved" },
      { "name" => "assigned_to", "value" => "{{customer_name}}" }
    ])
  end

  # Test 1.3.4: Question step interpolation
  test "question step interpolation displays correctly in scenario" do
    scenario = Scenario.create!(
      workflow: @workflow,
      user: @user,
      status: 'active',
      current_step_index: 0,
      results: {},
      inputs: {}
    )

    # First question should not have interpolation
    get step_scenario_path(scenario)

    assert_response :success
    assert_select "label", text: /What is your name\?/

    # Answer first question
    scenario.process_step("John Doe")
    scenario.save!

    # Now check second question with interpolation
    get step_scenario_path(scenario)

    assert_response :success

    # Should show interpolated question text
    assert_select "label", text: /Hello John Doe, what is your issue\?/
  end

  test "question step title and description interpolation" do
    workflow = Workflow.create!(title: "Title Interpolation Test", user: @user)
    Steps::Question.create!(workflow: workflow, position: 0, title: "Question for {{customer_name}}", question: "What is your issue?", variable_name: "issue", answer_type: "text")

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: 'active',
      current_step_index: 0,
      results: { "customer_name" => "Alice" },
      inputs: {}
    )

    get step_scenario_path(scenario)

    assert_response :success

    # Check title is interpolated
    assert_select "h2", text: /Question for Alice/
  end

  # Test 1.3.5: Action step interpolation
  test "action step instructions interpolation displays correctly" do
    scenario = Scenario.create!(
      workflow: @workflow,
      user: @user,
      status: 'active',
      current_step_index: 2, # Action step with interpolation
      results: { "customer_name" => "Bob", "issue" => "password reset" },
      inputs: {}
    )

    get step_scenario_path(scenario)

    assert_response :success

    # Should show interpolated instructions
    assert_select ".text-amber-900", text: /Send email to Bob about password reset/
  end

  test "action step title and description interpolation" do
    workflow = Workflow.create!(title: "Action Interpolation Test", user: @user)
    Steps::Action.create!(workflow: workflow, position: 0, title: "Action for {{customer_name}}", action_type: "Notification")

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: 'active',
      current_step_index: 0,
      results: { "customer_name" => "Charlie", "issue" => "billing" },
      inputs: {}
    )

    get step_scenario_path(scenario)

    assert_response :success

    # Check title is interpolated
    assert_select "h2", text: /Action for Charlie/
  end

  # Test 1.3.2: Output fields processing
  test "action step output fields are stored in scenario results" do
    scenario = Scenario.create!(
      workflow: @workflow,
      user: @user,
      status: 'active',
      current_step_index: 3, # Action step with output_fields
      results: { "customer_name" => "David" },
      inputs: {}
    )

    # Process the action step
    scenario.process_step
    scenario.save!

    # Check that output fields were stored
    assert_equal "resolved", scenario.results["status"]
    # Check that interpolated output field value was processed
    assert_equal "David", scenario.results["assigned_to"]
  end

  test "action step output fields with static values" do
    workflow = Workflow.create!(title: "Static Output Test", user: @user)
    Steps::Action.create!(workflow: workflow, position: 0, title: "Set Status", action_type: "Update", output_fields: [
      { "name" => "ticket_status", "value" => "open" },
      { "name" => "priority", "value" => "high" }
    ])

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: 'active',
      current_step_index: 0,
      results: {},
      inputs: {}
    )

    scenario.process_step
    scenario.save!

    assert_equal "open", scenario.results["ticket_status"]
    assert_equal "high", scenario.results["priority"]
  end

  test "action step output fields with interpolated values" do
    workflow = Workflow.create!(title: "Interpolated Output Test", user: @user)
    Steps::Question.create!(workflow: workflow, position: 0, title: "Get Name", question: "What is your name?", variable_name: "user_name", answer_type: "text")
    Steps::Action.create!(workflow: workflow, position: 1, title: "Set Email", action_type: "Update", output_fields: [
      { "name" => "email", "value" => "{{user_name}}@example.com" }
    ])

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: 'active',
      current_step_index: 0,
      results: {},
      inputs: {}
    )

    # Answer question first
    scenario.process_step("alice")
    scenario.save!

    # Process action step
    scenario.process_step
    scenario.save!

    # Check interpolated output field
    assert_equal "alice@example.com", scenario.results["email"]
  end

  test "action step with multiple output fields and mixed interpolation" do
    workflow = Workflow.create!(title: "Mixed Output Test", user: @user)
    Steps::Question.create!(workflow: workflow, position: 0, title: "Get Name", question: "Name?", variable_name: "name", answer_type: "text")
    Steps::Action.create!(workflow: workflow, position: 1, title: "Complex Output", action_type: "Update", output_fields: [
      { "name" => "static_var", "value" => "static_value" },
      { "name" => "interpolated_var", "value" => "Hello {{name}}" },
      { "name" => "mixed_var", "value" => "{{name}}_123" }
    ])

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: 'active',
      current_step_index: 0,
      results: {},
      inputs: {}
    )

    scenario.process_step("Bob")
    scenario.save!

    scenario.process_step
    scenario.save!

    assert_equal "static_value", scenario.results["static_var"]
    assert_equal "Hello Bob", scenario.results["interpolated_var"]
    assert_equal "Bob_123", scenario.results["mixed_var"]
  end

  test "missing variables in output fields are left as-is" do
    workflow = Workflow.create!(title: "Missing Var Test", user: @user)
    Steps::Action.create!(workflow: workflow, position: 0, title: "Test Missing", action_type: "Update", output_fields: [
      { "name" => "result", "value" => "{{missing_var}}" }
    ])

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: 'active',
      current_step_index: 0,
      results: {},
      inputs: {}
    )

    scenario.process_step
    scenario.save!

    # Missing variable should be left as-is (VariableInterpolator behavior for missing keys)
    assert_equal "{{missing_var}}", scenario.results["result"]
  end

  test "workflow variables method includes output_fields" do
    # Create AR steps for the variables method (which now queries AR steps)
    ar_workflow = Workflow.create!(title: "AR Variables Test", user: @user)
    Steps::Question.create!(workflow: ar_workflow, position: 0, title: "Name Question", question: "What is your name?", variable_name: "customer_name")
    Steps::Question.create!(workflow: ar_workflow, position: 1, title: "Issue Question", question: "What is your issue?", variable_name: "issue")
    Steps::Action.create!(workflow: ar_workflow, position: 2, title: "Notification", output_fields: [
      { "name" => "status", "value" => "resolved" },
      { "name" => "assigned_to", "value" => "agent1" }
    ])

    variables = ar_workflow.variables

    # Should include question variable_name
    assert_includes variables, "customer_name"
    assert_includes variables, "issue"

    # Should include action output_fields
    assert_includes variables, "status"
    assert_includes variables, "assigned_to"
  end
end
