require "test_helper"

class RunnerHelperTest < ActionView::TestCase
  include ScenariosHelper

  setup do
    @user = User.create!(
      email: "runner-helper-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    @workflow = Workflow.create!(title: "Runner Helper WF", user: @user)
  end

  test "option value and label accept hashes or plain strings" do
    assert_equal "yes", runner_option_value({ "value" => "yes", "label" => "Yes" })
    assert_equal "Yes", runner_option_label({ "value" => "yes", "label" => "Yes" })

    # Authored as a bare string — the Scenario runner used to render nothing here.
    assert_equal "Escalate", runner_option_value("Escalate")
    assert_equal "Escalate", runner_option_label("Escalate")
  end

  test "option value falls back to label when only one is present" do
    assert_equal "Yes", runner_option_value({ "label" => "Yes" })
    assert_equal "yes", runner_option_label({ "value" => "yes" })
  end

  test "input type and placeholder follow the answer type" do
    assert_equal "number", runner_input_type("number")
    assert_equal "date", runner_input_type("date")
    assert_equal "text", runner_input_type("free_text")
    assert_equal "text", runner_input_type(nil)

    assert_equal "Enter a number", runner_input_placeholder("number")
    assert_equal "YYYY-MM-DD", runner_input_placeholder("date")
    assert_equal "Type your answer...", runner_input_placeholder(nil)
  end

  test "trail lists this scenario's answered steps oldest first" do
    scenario = Scenario.create!(
      workflow: @workflow, user: @user, inputs: {},
      execution_path: [
        { "step_title" => "Confirm Issue", "answer" => "yes", "step_type" => "question" },
        { "step_title" => "Check hosting", "step_type" => "action" }
      ]
    )

    entries = runner_trail_entries(scenario)

    assert_equal ["Confirm Issue", "Check hosting"], entries.map { |e| e["step_title"] }
    assert_equal "yes", entries.first["answer"]
  end

  test "trail inside a sub-flow shows the steps that led into it" do
    child = Scenario.create!(
      workflow: @workflow, user: @user, inputs: {},
      execution_path: [ { "step_title" => "Verify identity", "answer" => "yes", "step_type" => "question" } ]
    )
    parent = Scenario.create!(
      workflow: @workflow, user: @user, inputs: {}, status: "awaiting_subflow",
      execution_path: [
        { "step_title" => "Confirm Issue", "answer" => "yes", "step_type" => "question" },
        { "subflow_started" => true, "child_scenario_id" => child.id, "step_type" => "sub_flow" }
      ]
    )
    child.update!(parent_scenario: parent)

    # Read from the child, as the runner does while inside a sub-flow. The old
    # stepper showed only the child's own path numbered from 1, beside a counter
    # that counted across ancestors — "Step 1" sitting next to "Step 4".
    entries = runner_trail_entries(child)

    assert_equal ["Confirm Issue", "Verify identity"], entries.map { |e| e["step_title"] },
                 "the trail must span the whole run, not the sub-flow frame"
  end

  test "trail is empty for a run that has not answered anything yet" do
    scenario = Scenario.create!(workflow: @workflow, user: @user, inputs: {}, execution_path: [])

    assert_empty runner_trail_entries(scenario)
  end
end
