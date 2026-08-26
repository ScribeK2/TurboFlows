require "test_helper"

class ScenariosHelperTest < ActionView::TestCase
  include ScenariosHelper
  include WorkflowsHelper

  setup do
    @user = User.create!(
      email: "scenario-helper-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
  end

  test "scenario_summary_sentence formats duration counts and resolution" do
    wf = Workflow.create!(title: "Summary WF", user: @user)
    scenario = Scenario.create!(
      workflow: wf, user: @user,
      started_at: 2.minutes.ago, completed_at: Time.current,
      duration_seconds: 134,
      execution_path: [
        { "step_type" => "question" },
        { "step_type" => "question" },
        { "step_type" => "action" }
      ],
      results: { "_resolution" => { "type" => "success" } },
      inputs: {}, purpose: "simulation"
    )
    result = scenario_summary_sentence(scenario)
    assert_includes result, "3 steps"
    assert_includes result, "2m"
    assert_includes result, "2 questions answered"
    assert_includes result, "1 action performed"
    assert_includes result, "resolved as Success"
  end

  test "format_result_key strips step prefix and titleizes" do
    assert_equal "Outlook Success Check", format_result_key("step_6_outlook_success_check")
    assert_equal "Customer Name", format_result_key("customer_name")
  end

  test "categorize_scenario_results separates inputs from outcomes" do
    wf = Workflow.create!(title: "Cat WF", user: @user)
    scenario = Scenario.create!(
      workflow: wf, user: @user,
      inputs: { "name" => "Alice" },
      results: { "name" => "Alice", "status" => "resolved" },
      purpose: "simulation"
    )
    groups = categorize_scenario_results(scenario)
    assert_equal 2, groups.length
    assert_equal "User Inputs", groups[0][:label]
    assert groups[0][:results].key?("name")
    assert_equal "Outcomes", groups[1][:label]
    assert groups[1][:results].key?("status")
  end

  test "categorize_scenario_results returns empty for no results" do
    wf = Workflow.create!(title: "Empty WF", user: @user)
    scenario = Scenario.create!(workflow: wf, user: @user, results: {}, inputs: {}, purpose: "simulation")
    assert_equal [], categorize_scenario_results(scenario)
  end

  test "flattened_execution_path merges child steps into parent path" do
    parent_wf = Workflow.create!(title: "Parent WF", user: @user)
    child_wf = Workflow.create!(title: "Child WF", user: @user)

    child = Scenario.create!(
      workflow: child_wf, user: @user, purpose: "simulation", status: "completed",
      execution_path: [
        { "step_title" => "C1", "step_type" => "question", "answer" => "yes" },
        { "step_title" => "C2", "step_type" => "resolve", "resolved" => true }
      ],
      inputs: {}
    )

    parent = Scenario.create!(
      workflow: parent_wf, user: @user, purpose: "simulation", status: "completed",
      execution_path: [
        { "step_title" => "P1", "step_type" => "question", "answer" => "hello" },
        { "step_title" => "Run Child", "step_type" => "sub_flow", "subflow_started" => true, "child_scenario_id" => child.id },
        { "step_title" => "P2", "step_type" => "resolve", "resolved" => true }
      ],
      inputs: {}
    )
    child.update!(parent_scenario: parent)

    flat = flattened_execution_path(parent)
    assert_equal 3, flat.length
    assert_equal "P1", flat[0]["step_title"]
    assert_equal "C1", flat[1]["step_title"]
    assert_equal "P2", flat[2]["step_title"]
  end

  test "flattened_execution_path handles nested sub-flows recursively" do
    grandchild_wf = Workflow.create!(title: "Grandchild WF", user: @user)
    child_wf = Workflow.create!(title: "Child WF", user: @user)
    parent_wf = Workflow.create!(title: "Parent WF", user: @user)

    grandchild = Scenario.create!(
      workflow: grandchild_wf, user: @user, purpose: "simulation", status: "completed",
      execution_path: [
        { "step_title" => "GC1", "step_type" => "action" },
        { "step_title" => "GC2", "step_type" => "resolve", "resolved" => true }
      ],
      inputs: {}
    )

    child = Scenario.create!(
      workflow: child_wf, user: @user, purpose: "simulation", status: "completed",
      execution_path: [
        { "step_title" => "C1", "step_type" => "question", "answer" => "yes" },
        { "step_title" => "Run GC", "step_type" => "sub_flow", "subflow_started" => true, "child_scenario_id" => grandchild.id },
        { "step_title" => "C2", "step_type" => "resolve", "resolved" => true }
      ],
      inputs: {}
    )
    grandchild.update!(parent_scenario: child)

    parent = Scenario.create!(
      workflow: parent_wf, user: @user, purpose: "simulation", status: "completed",
      execution_path: [
        { "step_title" => "P1", "step_type" => "action" },
        { "step_title" => "Run Child", "step_type" => "sub_flow", "subflow_started" => true, "child_scenario_id" => child.id },
        { "step_title" => "P2", "step_type" => "resolve", "resolved" => true }
      ],
      inputs: {}
    )
    child.update!(parent_scenario: parent)

    flat = flattened_execution_path(parent)
    assert_equal 4, flat.length
    assert_equal "P1", flat[0]["step_title"]
    assert_equal "C1", flat[1]["step_title"]
    assert_equal "GC1", flat[2]["step_title"]
    assert_equal "P2", flat[3]["step_title"]
  end

  test "flattened_execution_path excludes child escalate terminal steps" do
    parent_wf = Workflow.create!(title: "Parent WF", user: @user)
    child_wf = Workflow.create!(title: "Child WF", user: @user)

    child = Scenario.create!(
      workflow: child_wf, user: @user, purpose: "simulation", status: "completed",
      execution_path: [
        { "step_title" => "C1", "step_type" => "question", "answer" => "yes" },
        { "step_title" => "C2", "step_type" => "escalate", "escalated" => true }
      ],
      inputs: {}
    )

    parent = Scenario.create!(
      workflow: parent_wf, user: @user, purpose: "simulation", status: "completed",
      execution_path: [
        { "step_title" => "P1", "step_type" => "action" },
        { "step_title" => "Run Child", "step_type" => "sub_flow", "subflow_started" => true, "child_scenario_id" => child.id },
        { "step_title" => "P2", "step_type" => "resolve", "resolved" => true }
      ],
      inputs: {}
    )
    child.update!(parent_scenario: parent)

    flat = flattened_execution_path(parent)
    assert_equal 3, flat.length
    assert_equal "C1", flat[1]["step_title"]
  end

  test "flattened_execution_path returns normal path when no sub-flows" do
    wf = Workflow.create!(title: "Normal WF", user: @user)
    scenario = Scenario.create!(
      workflow: wf, user: @user, purpose: "simulation", status: "completed",
      execution_path: [
        { "step_title" => "S1", "step_type" => "question", "answer" => "yes" },
        { "step_title" => "S2", "step_type" => "resolve", "resolved" => true }
      ],
      inputs: {}
    )

    flat = flattened_execution_path(scenario)
    assert_equal 2, flat.length
    assert_equal "S1", flat[0]["step_title"]
    assert_equal "S2", flat[1]["step_title"]
  end
  test "scenario_back_button posts rather than linking to a GET" do
    wf = Workflow.create!(title: "Back WF", user: @user)
    scenario = Scenario.create!(
      workflow: wf, user: @user, purpose: "simulation", inputs: {}, results: {},
      execution_path: [{ "step_title" => "S1", "step_type" => "question", "results_delta" => {} }]
    )

    result = scenario_back_button(scenario)

    assert_includes result, back_scenario_path(scenario)
    assert_includes result, "post",
                    "a GET that rewinds the run is fired by Turbo's hover prefetch"
  end

  test "scenario_back_button is hidden for a run whose entries predate the undo log" do
    wf = Workflow.create!(title: "Back WF", user: @user)
    scenario = Scenario.create!(
      workflow: wf, user: @user, purpose: "simulation", inputs: {}, results: {},
      execution_path: [{ "step_title" => "S1", "step_type" => "question" }]
    )

    assert_nil scenario_back_button(scenario)
  end
end
