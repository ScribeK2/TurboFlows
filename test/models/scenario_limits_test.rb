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

  test "step-by-step processing tracks iterations" do
    workflow = Workflow.create!(title: "Step Workflow", user: @user)
    q1 = Steps::Question.create!(workflow: workflow, position: 0, uuid: "q-1", title: "Q1", question: "First?", variable_name: "q1")
    q2 = Steps::Question.create!(workflow: workflow, position: 1, uuid: "q-2", title: "Q2", question: "Second?", variable_name: "q2")
    Transition.create!(step: q1, target_step: q2, position: 0)
    workflow.update_column(:start_step_id, q1.id)

    scenario = Scenario.create!(
      workflow: workflow,
      user: @user,
      status: 'active',
      current_node_uuid: "q-1",
      purpose: "simulation"
    )

    # Process first step
    scenario.process_step("answer1")

    assert_equal "q-2", scenario.current_node_uuid

    # Process second step
    scenario.process_step("answer2")

    # Should be complete (no more transitions)
    assert_predicate scenario, :complete?
  end
end
