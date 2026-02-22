require "test_helper"

class SimulationTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(
      email: "test@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    @workflow = Workflow.create!(
      title: "Test Workflow",
      description: "A test workflow",
      user: @user,
      steps: [
        { type: "question", title: "Question 1", question: "What is your name?" },
        { type: "action", title: "Action Check", instructions: "Check the answer" },
        { type: "action", title: "Action 1", instructions: "Do something" }
      ]
    )
  end

  test "should create simulation with valid attributes" do
    simulation = Simulation.new(
      workflow: @workflow,
      user: @user,
      inputs: { "0" => "John Doe" }
    )

    assert_predicate simulation, :valid?
    assert simulation.save
  end

  test "should belong to workflow" do
    simulation = Simulation.create!(
      workflow: @workflow,
      user: @user,
      inputs: {}
    )

    assert_equal @workflow, simulation.workflow
  end

  test "should belong to user" do
    simulation = Simulation.create!(
      workflow: @workflow,
      user: @user,
      inputs: {}
    )

    assert_equal @user, simulation.user
  end

  test "execute should process workflow steps" do
    simulation = Simulation.create!(
      workflow: @workflow,
      user: @user,
      inputs: { "Question 1" => "John Doe" }
    )

    assert simulation.execute
    assert_predicate simulation.execution_path, :present?
    assert_predicate simulation.results, :present?
    assert_predicate simulation.execution_path, :any?
  end

  test "execute should track execution path" do
    simulation = Simulation.create!(
      workflow: @workflow,
      user: @user,
      inputs: { "Question 1" => "John Doe" }
    )

    simulation.execute

    assert_kind_of Array, simulation.execution_path
    assert_predicate simulation.execution_path.first["step_title"], :present?
  end

  test "execute should store results" do
    simulation = Simulation.create!(
      workflow: @workflow,
      user: @user,
      inputs: { "Question 1" => "John Doe" }
    )

    simulation.execute

    assert_kind_of Hash, simulation.results
  end
end
