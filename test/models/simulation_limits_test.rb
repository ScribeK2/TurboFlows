require "test_helper"

class SimulationLimitsTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(
      email: "test@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
  end

  test "simulation constants are defined and reasonable" do
    assert_operator Simulation::MAX_ITERATIONS, :>=, 100, "MAX_ITERATIONS should allow reasonable workflow size"
    assert_operator Simulation::MAX_ITERATIONS, :<=, 10_000, "MAX_ITERATIONS should prevent DoS"

    assert_operator Simulation::MAX_EXECUTION_TIME, :>=, 10, "MAX_EXECUTION_TIME should allow reasonable workflows"
    assert_operator Simulation::MAX_EXECUTION_TIME, :<=, 120, "MAX_EXECUTION_TIME should prevent resource hogging"

    assert_operator Simulation::MAX_CONDITION_DEPTH, :>=, 10, "MAX_CONDITION_DEPTH should allow nested conditions"
  end

  test "simulation statuses include timeout and error" do
    assert_includes Simulation::STATUSES, 'timeout'
    assert_includes Simulation::STATUSES, 'error'
  end

  test "execute_with_limits stops at iteration limit" do
    # Create a workflow with an infinite loop (branches back to step 1)
    workflow = Workflow.create!(
      title: "Infinite Loop Workflow",
      user: @user,
      steps: [
        {
          "type" => "question",
          "title" => "Step 1",
          "question" => "What?",
          "variable_name" => "answer"
        },
        {
          "type" => "question",
          "title" => "Loop Back",
          "question" => "Continue looping?"
        }
      ]
    )

    simulation = Simulation.create!(
      workflow: workflow,
      user: @user,
      status: 'active',
      inputs: { "answer" => "loop" }
    )

    # Execute should return false when hitting limits
    result = simulation.execute

    assert_not result, "Execute should return false when hitting iteration limit"

    simulation.reload

    assert_equal 'error', simulation.status
    assert_predicate simulation.results['_error'], :present?
    assert_includes simulation.results['_error'], 'iterations'
  end

  test "normal workflows complete within limits" do
    workflow = Workflow.create!(
      title: "Normal Workflow",
      user: @user,
      steps: [
        {
          "type" => "question",
          "title" => "Name",
          "question" => "What is your name?",
          "variable_name" => "name"
        },
        {
          "type" => "action",
          "title" => "Greet",
          "instructions" => "Say hello"
        }
      ]
    )

    simulation = Simulation.create!(
      workflow: workflow,
      user: @user,
      status: 'active',
      inputs: { "name" => "Test User" }
    )

    # Should complete normally
    result = simulation.execute

    assert result, "Normal workflow should complete successfully"

    simulation.reload

    assert_equal 2, simulation.execution_path.length
    assert_predicate simulation.results['name'], :present?
  end

  test "step-by-step processing tracks iterations" do
    workflow = Workflow.create!(
      title: "Step Workflow",
      user: @user,
      steps: [
        { "type" => "question", "title" => "Q1", "question" => "First?", "variable_name" => "q1" },
        { "type" => "question", "title" => "Q2", "question" => "Second?", "variable_name" => "q2" }
      ]
    )

    simulation = Simulation.create!(
      workflow: workflow,
      user: @user,
      status: 'active',
      current_step_index: 0
    )

    # Process first step
    simulation.process_step("answer1")

    assert_equal 1, simulation.current_step_index

    # Process second step
    simulation.process_step("answer2")

    assert_equal 2, simulation.current_step_index

    # Should be complete
    assert_predicate simulation, :complete?
  end
end
