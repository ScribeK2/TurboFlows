require "test_helper"

# Test 1.3.2: Output fields for action steps
class ScenarioOutputFieldsTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(
      email: "test@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
  end

  test "action step processes output_fields and stores in results" do
    workflow = Workflow.create!(title: "Output Fields Test", user: @user)
    Steps::Action.create!(
      workflow: workflow,
      position: 0,
      title: "Set Status",
      action_type: "Update",
      output_fields: [
        { "name" => "status", "value" => "completed" },
        { "name" => "priority", "value" => "high" }
      ]
    )

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: "active",
      current_step_index: 0,
      results: {},
      inputs: {}
    )

    scenario.process_step
    scenario.save!

    assert_equal "completed", scenario.results["status"]
    assert_equal "high", scenario.results["priority"]
  end

  test "action step output_fields with interpolated values" do
    workflow = Workflow.create!(title: "Interpolated Output Test", user: @user)
    Steps::Question.create!(
      workflow: workflow,
      position: 0,
      title: "Get Name",
      question: "What is your name?",
      variable_name: "user_name",
      answer_type: "text"
    )
    Steps::Action.create!(
      workflow: workflow,
      position: 1,
      title: "Set Email",
      action_type: "Update",
      output_fields: [
        { "name" => "email", "value" => "{{user_name}}@example.com" }
      ]
    )

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: "active",
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

  test "action step with multiple output_fields and mixed interpolation" do
    workflow = Workflow.create!(title: "Mixed Output Test", user: @user)
    Steps::Question.create!(
      workflow: workflow,
      position: 0,
      title: "Get Name",
      question: "Name?",
      variable_name: "name",
      answer_type: "text"
    )
    Steps::Action.create!(
      workflow: workflow,
      position: 1,
      title: "Complex Output",
      action_type: "Update",
      output_fields: [
        { "name" => "static_var", "value" => "static_value" },
        { "name" => "interpolated_var", "value" => "Hello {{name}}" },
        { "name" => "mixed_var", "value" => "{{name}}_123" }
      ]
    )

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: "active",
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

  test "missing variables in output_fields leave pattern as-is" do
    workflow = Workflow.create!(title: "Missing Var Test", user: @user)
    Steps::Action.create!(
      workflow: workflow,
      position: 0,
      title: "Test Missing",
      action_type: "Update",
      output_fields: [
        { "name" => "result", "value" => "{{missing_var}}" }
      ]
    )

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: "active",
      current_step_index: 0,
      results: {},
      inputs: {}
    )

    scenario.process_step
    scenario.save!

    # Missing variable should be left as-is
    assert_equal "{{missing_var}}", scenario.results["result"]
  end

  test "action step without output_fields still works" do
    workflow = Workflow.create!(title: "No Output Fields Test", user: @user)
    Steps::Action.create!(
      workflow: workflow,
      position: 0,
      title: "Simple Action",
      action_type: "Notification"
    )

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: "active",
      current_step_index: 0,
      results: {},
      inputs: {}
    )

    assert_nothing_raised do
      scenario.process_step
      scenario.save!
    end

    # Should still mark action as executed
    assert_equal "Action executed", scenario.results["Simple Action"]
  end

  test "output_fields skips entries with empty names at runtime" do
    workflow = Workflow.create!(title: "Empty Name Test", user: @user)
    Steps::Action.create!(
      workflow: workflow,
      position: 0,
      title: "Test",
      action_type: "Update",
      output_fields: [
        { "name" => "", "value" => "should_not_be_stored" },
        { "name" => "valid_name", "value" => "should_be_stored" }
      ]
    )

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: "active",
      current_step_index: 0,
      results: {},
      inputs: {}
    )

    scenario.process_step
    scenario.save!

    # Empty-name field is skipped, valid field is stored
    assert_equal "should_be_stored", scenario.results["valid_name"]
    assert_not scenario.results.key?("")
  end

  test "output_fields can reference variables from previous action steps" do
    workflow = Workflow.create!(title: "Chained Output Test", user: @user)
    Steps::Action.create!(
      workflow: workflow,
      position: 0,
      title: "Set First",
      action_type: "Update",
      output_fields: [
        { "name" => "first_var", "value" => "first_value" }
      ]
    )
    Steps::Action.create!(
      workflow: workflow,
      position: 1,
      title: "Set Second",
      action_type: "Update",
      output_fields: [
        { "name" => "second_var", "value" => "{{first_var}}_second" }
      ]
    )

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: "active",
      current_step_index: 0,
      results: {},
      inputs: {}
    )

    # Process first action
    scenario.process_step
    scenario.save!

    # Process second action (should interpolate from first)
    scenario.process_step
    scenario.save!

    assert_equal "first_value", scenario.results["first_var"]
    assert_equal "first_value_second", scenario.results["second_var"]
  end
end
