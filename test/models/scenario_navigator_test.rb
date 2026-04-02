require "test_helper"

class ScenarioNavigatorTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "nav-test@example.com", password: "password123456")
    @workflow = Workflow.create!(title: "Nav WF", user: @user)
    @q1 = Steps::Question.create!(workflow: @workflow, title: "Q1", position: 0, variable_name: "q1_var")
    @q2 = Steps::Question.create!(workflow: @workflow, title: "Q2", position: 1)
    @resolve = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 2)
    Transition.create!(step: @q1, target_step: @q2, position: 0)
    Transition.create!(step: @q2, target_step: @resolve, position: 0)
    @workflow.update!(start_step: @q1)

    @scenario = Scenario.create!(
      workflow: @workflow, user: @user, purpose: "simulation",
      current_node_uuid: @q2.uuid,
      execution_path: [
        { "step_title" => "Q1", "step_type" => "question", "step_uuid" => @q1.uuid, "answer" => "Yes" }
      ],
      results: { "Q1" => "Yes", "q1_var" => "Yes" },
      inputs: { "q1_var" => "Yes", "Q1" => "Yes" }
    )
  end

  test "go_back pops to last interactive step and rebuilds state" do
    navigator = ScenarioNavigator.new(@scenario, @workflow)
    navigator.go_back

    assert_equal @q1.uuid, @scenario.current_node_uuid
    assert_empty @scenario.execution_path
    assert_empty @scenario.results
    assert_empty @scenario.inputs
  end

  test "go_back skips sub_flow entries" do
    @scenario.execution_path << { "step_title" => "SF", "step_type" => "sub_flow", "step_uuid" => "sf-uuid" }
    @scenario.execution_path << { "step_title" => "Q2", "step_type" => "question", "step_uuid" => @q2.uuid, "answer" => "No" }

    navigator = ScenarioNavigator.new(@scenario, @workflow)
    navigator.go_back

    assert_equal @q2.uuid, @scenario.current_node_uuid
  end

  test "go_back does nothing when execution_path is empty" do
    @scenario.execution_path = []
    @scenario.save!
    original_uuid = @scenario.current_node_uuid

    navigator = ScenarioNavigator.new(@scenario, @workflow)
    navigator.go_back

    assert_equal original_uuid, @scenario.current_node_uuid
  end

  test "go_back resets status to active when scenario is completed" do
    @scenario.update!(status: "completed")

    navigator = ScenarioNavigator.new(@scenario, @workflow)
    navigator.go_back

    @scenario.reload
    assert_equal "active", @scenario.status
  end

  test "go_back rebuilds results using step variable_name" do
    @scenario.execution_path = [
      { "step_title" => "Q1", "step_type" => "question", "step_uuid" => @q1.uuid, "answer" => "Yes" },
      { "step_title" => "Q2", "step_type" => "question", "step_uuid" => @q2.uuid, "answer" => "No" }
    ]
    @scenario.current_node_uuid = @resolve.uuid
    @scenario.save!

    navigator = ScenarioNavigator.new(@scenario, @workflow)
    navigator.go_back

    # After going back from Q2, Q1's answer should still be in results
    assert_equal "Yes", @scenario.results["Q1"]
    assert_equal "Yes", @scenario.results["q1_var"]
    assert_equal "Yes", @scenario.inputs["q1_var"]
  end
end
