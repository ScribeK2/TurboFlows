require "test_helper"

class ScenarioTest < ActiveSupport::TestCase
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

  test "should create scenario with valid attributes" do
    scenario = Scenario.new(
      workflow: @workflow,
      user: @user,
      inputs: { "0" => "John Doe" }
    )

    assert_predicate scenario, :valid?
    assert scenario.save
  end

  test "should belong to workflow" do
    scenario = Scenario.create!(
      workflow: @workflow,
      user: @user,
      inputs: {}
    )

    assert_equal @workflow, scenario.workflow
  end

  test "should belong to user" do
    scenario = Scenario.create!(
      workflow: @workflow,
      user: @user,
      inputs: {}
    )

    assert_equal @user, scenario.user
  end

  test "execute should process workflow steps" do
    scenario = Scenario.create!(
      workflow: @workflow,
      user: @user,
      inputs: { "Question 1" => "John Doe" }
    )

    assert scenario.execute
    assert_predicate scenario.execution_path, :present?
    assert_predicate scenario.results, :present?
    assert_predicate scenario.execution_path, :any?
  end

  test "execute should track execution path" do
    scenario = Scenario.create!(
      workflow: @workflow,
      user: @user,
      inputs: { "Question 1" => "John Doe" }
    )

    scenario.execute

    assert_kind_of Array, scenario.execution_path
    assert_predicate scenario.execution_path.first["step_title"], :present?
  end

  test "execute should store results" do
    scenario = Scenario.create!(
      workflow: @workflow,
      user: @user,
      inputs: { "Question 1" => "John Doe" }
    )

    scenario.execute

    assert_kind_of Hash, scenario.results
  end
end
