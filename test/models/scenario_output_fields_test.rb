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
    workflow = Workflow.create!(
      title: "Output Fields Test",
      user: @user,
      steps: [
        {
          type: "action",
          title: "Set Status",
          action_type: "Update",
          instructions: "Update status",
          output_fields: [
            { name: "status", value: "completed" },
            { name: "priority", value: "high" }
          ]
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

    scenario.process_step
    scenario.save!

    assert_equal "completed", scenario.results["status"]
    assert_equal "high", scenario.results["priority"]
  end

  test "action step output_fields with interpolated values" do
    workflow = Workflow.create!(
      title: "Interpolated Output Test",
      user: @user,
      steps: [
        {
          type: "question",
          title: "Get Name",
          question: "What is your name?",
          variable_name: "user_name",
          answer_type: "text"
        },
        {
          type: "action",
          title: "Set Email",
          action_type: "Update",
          instructions: "Set email",
          output_fields: [
            { name: "email", value: "{{user_name}}@example.com" }
          ]
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
    workflow = Workflow.create!(
      title: "Mixed Output Test",
      user: @user,
      steps: [
        {
          type: "question",
          title: "Get Name",
          question: "Name?",
          variable_name: "name",
          answer_type: "text"
        },
        {
          type: "action",
          title: "Complex Output",
          action_type: "Update",
          instructions: "Set values",
          output_fields: [
            { name: "static_var", value: "static_value" },
            { name: "interpolated_var", value: "Hello {{name}}" },
            { name: "mixed_var", value: "{{name}}_123" }
          ]
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

    scenario.process_step("Bob")
    scenario.save!

    scenario.process_step
    scenario.save!

    assert_equal "static_value", scenario.results["static_var"]
    assert_equal "Hello Bob", scenario.results["interpolated_var"]
    assert_equal "Bob_123", scenario.results["mixed_var"]
  end

  test "missing variables in output_fields leave pattern as-is" do
    workflow = Workflow.create!(
      title: "Missing Var Test",
      user: @user,
      steps: [
        {
          type: "action",
          title: "Test Missing",
          action_type: "Update",
          instructions: "Test",
          output_fields: [
            { name: "result", value: "{{missing_var}}" }
          ]
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

    scenario.process_step
    scenario.save!

    # Missing variable should be left as-is
    assert_equal "{{missing_var}}", scenario.results["result"]
  end

  test "action step without output_fields still works" do
    workflow = Workflow.create!(
      title: "No Output Fields Test",
      user: @user,
      steps: [
        {
          type: "action",
          title: "Simple Action",
          action_type: "Notification",
          instructions: "Do something"
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

    assert_nothing_raised do
      scenario.process_step
      scenario.save!
    end

    # Should still mark action as executed
    assert_equal "Action executed", scenario.results["Simple Action"]
  end

  test "output_fields validation prevents empty names" do
    workflow = Workflow.new(
      title: "Empty Name Test",
      user: @user,
      steps: [
        {
          type: "action",
          title: "Test",
          action_type: "Update",
          instructions: "Test",
          output_fields: [
            { name: "", value: "should_not_be_stored" },
            { name: "valid_name", value: "should_be_stored" }
          ]
        }
      ]
    )

    # Should fail validation due to empty name
    assert_not workflow.valid?
    assert(workflow.errors.full_messages.any? { |msg| msg.include?("Output Field 1: name is required") })
  end

  test "output_fields can reference variables from previous action steps" do
    workflow = Workflow.create!(
      title: "Chained Output Test",
      user: @user,
      steps: [
        {
          type: "action",
          title: "Set First",
          action_type: "Update",
          instructions: "Set first",
          output_fields: [
            { name: "first_var", value: "first_value" }
          ]
        },
        {
          type: "action",
          title: "Set Second",
          action_type: "Update",
          instructions: "Set second",
          output_fields: [
            { name: "second_var", value: "{{first_var}}_second" }
          ]
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
