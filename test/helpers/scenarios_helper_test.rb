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

  test "scenario_step_counter shows Step X for any workflow" do
    wf = Workflow.create!(title: "Graph WF", user: @user)
    Steps::Action.create!(workflow: wf, position: 0, title: "S1")
    Steps::Action.create!(workflow: wf, position: 1, title: "S2")
    Steps::Action.create!(workflow: wf, position: 2, title: "S3")
    scenario = Scenario.create!(workflow: wf, user: @user, execution_path: [{ "step_title" => "S1" }], inputs: {}, purpose: "simulation")
    result = scenario_step_counter(scenario, wf)
    assert_equal "Step 2", result
  end

  test "scenario_step_counter shows Step X for graph mode workflow" do
    wf = Workflow.create!(title: "Graph WF", user: @user, graph_mode: true)
    Steps::Action.create!(workflow: wf, position: 0, title: "S1")
    scenario = Scenario.create!(workflow: wf, user: @user, execution_path: [{ "step_title" => "S1" }, { "step_title" => "S2" }], inputs: {}, purpose: "simulation")
    result = scenario_step_counter(scenario, wf)
    assert_equal "Step 3", result
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

  test "scenario_stepper_classes returns correct classes for states" do
    assert_equal "stepper-pill stepper-pill--current", scenario_stepper_classes(false, true)
    assert_includes scenario_stepper_classes(true, false, "question"), "stepper-pill--question"
    assert_equal "stepper-pill stepper-pill--pending", scenario_stepper_classes(false, false)
  end

  test "scenario_step_number_classes returns badge class for step type" do
    assert_equal "badge badge--question", scenario_step_number_classes("question")
    assert_equal "badge badge--action", scenario_step_number_classes("action")
    assert_equal "badge", scenario_step_number_classes("unknown")
  end
end
