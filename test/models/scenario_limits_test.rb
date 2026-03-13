require "test_helper"

class ScenarioLimitsTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(
      email: "test@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
  end

  test "scenario constants are defined and reasonable" do
    assert_operator Scenario::MAX_ITERATIONS, :>=, 100, "MAX_ITERATIONS should allow reasonable workflow size"
    assert_operator Scenario::MAX_ITERATIONS, :<=, 10_000, "MAX_ITERATIONS should prevent DoS"

    assert_operator Scenario::MAX_EXECUTION_TIME, :>=, 10, "MAX_EXECUTION_TIME should allow reasonable workflows"
    assert_operator Scenario::MAX_EXECUTION_TIME, :<=, 120, "MAX_EXECUTION_TIME should prevent resource hogging"

    assert_operator Scenario::MAX_CONDITION_DEPTH, :>=, 10, "MAX_CONDITION_DEPTH should allow nested conditions"
  end

  test "scenario statuses include timeout and error" do
    assert_includes Scenario::STATUSES, 'timeout'
    assert_includes Scenario::STATUSES, 'error'
  end

  test "process_step stops at iteration limit" do
    # Create a graph-mode workflow with an infinite loop (action loops back to question)
    workflow = Workflow.create!(title: "Infinite Loop Workflow", user: @user, graph_mode: true)
    step1 = Steps::Question.create!(workflow: workflow, position: 0, uuid: "step-1", title: "Step 1", question: "What?", variable_name: "answer")
    step2 = Steps::Action.create!(workflow: workflow, position: 1, uuid: "step-2", title: "Loop Back")
    Transition.create!(step: step1, target_step: step2, position: 0)
    Transition.create!(step: step2, target_step: step1, position: 0)
    workflow.update_column(:start_step_id, step1.id)

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: 'active',
      current_node_uuid: 'step-1',
      inputs: { "answer" => "loop" }
    )

    # Process steps in a loop until iteration limit is hit
    assert_raises(Scenario::ScenarioIterationLimit) do
      (Scenario::MAX_ITERATIONS + 10).times do
        break unless scenario.process_step("loop")
      end
    end

    scenario.reload

    assert_equal 'errored', scenario.status
    assert_predicate scenario.results['_error'], :present?
    assert_includes scenario.results['_error'], 'iterations'
  end

  test "normal workflows complete within limits" do
    workflow = Workflow.create!(title: "Normal Workflow", user: @user)
    Steps::Question.create!(workflow: workflow, position: 0, title: "Name", question: "What is your name?", variable_name: "name")
    Steps::Action.create!(workflow: workflow, position: 1, title: "Greet")

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: 'active',
      inputs: { "name" => "Test User" }
    )

    # Should complete normally
    result = scenario.execute

    assert result, "Normal workflow should complete successfully"

    scenario.reload

    assert_equal 2, scenario.execution_path.length
    assert_predicate scenario.results['name'], :present?
  end

  test "step-by-step processing tracks iterations" do
    workflow = Workflow.create!(title: "Step Workflow", user: @user)
    Steps::Question.create!(workflow: workflow, position: 0, title: "Q1", question: "First?", variable_name: "q1")
    Steps::Question.create!(workflow: workflow, position: 1, title: "Q2", question: "Second?", variable_name: "q2")

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: 'active',
      current_step_index: 0
    )

    # Process first step
    scenario.process_step("answer1")

    assert_equal 1, scenario.current_step_index

    # Process second step
    scenario.process_step("answer2")

    assert_equal 2, scenario.current_step_index

    # Should be complete
    assert_predicate scenario, :complete?
  end
end
