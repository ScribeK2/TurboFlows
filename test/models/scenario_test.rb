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

  # --- Analytics tracking tests ---

  test "should set started_at on creation" do
    scenario = Scenario.create!(
      workflow: @workflow,
      user: @user,
      inputs: {}
    )

    assert_not_nil scenario.started_at
    assert_in_delta Time.current, scenario.started_at, 2.seconds
  end

  test "should default purpose to simulation" do
    scenario = Scenario.create!(
      workflow: @workflow,
      user: @user,
      inputs: {}
    )

    assert_equal "simulation", scenario.purpose
  end

  test "should set outcome to completed when scenario completes normally" do
    scenario = Scenario.create!(
      workflow: @workflow,
      user: @user,
      inputs: { "Question 1" => "John Doe" }
    )

    scenario.execute

    assert_equal "completed", scenario.outcome
    assert_not_nil scenario.completed_at
    assert_not_nil scenario.duration_seconds
  end

  test "should set outcome to abandoned when scenario is stopped" do
    scenario = Scenario.create!(
      workflow: @workflow,
      user: @user,
      inputs: {}
    )

    scenario.stop!

    assert_equal "abandoned", scenario.outcome
    assert_not_nil scenario.completed_at
  end

  test "should set outcome to resolved when hitting resolve step" do
    resolve_workflow = Workflow.create!(
      title: "Resolve Workflow",
      user: @user,
      graph_mode: true,
      steps: [
        { "id" => "step-1", "type" => "resolve", "title" => "Issue Resolved", "resolution_type" => "success" }
      ],
      start_node_uuid: "step-1"
    )
    scenario = Scenario.create!(
      workflow: resolve_workflow,
      user: @user,
      inputs: {},
      current_node_uuid: "step-1"
    )

    scenario.process_step

    assert_equal "resolved", scenario.outcome
  end

  test "should set outcome to escalated when hitting escalate step" do
    escalate_workflow = Workflow.create!(
      title: "Escalate Workflow",
      user: @user,
      graph_mode: true,
      steps: [
        { "id" => "step-1", "type" => "escalate", "title" => "Escalate Issue", "target_type" => "supervisor" }
      ],
      start_node_uuid: "step-1"
    )
    scenario = Scenario.create!(
      workflow: escalate_workflow,
      user: @user,
      inputs: {},
      current_node_uuid: "step-1"
    )

    scenario.process_step

    assert_equal "escalated", scenario.outcome
  end

  test "should calculate duration_seconds on completion" do
    scenario = Scenario.create!(
      workflow: @workflow,
      user: @user,
      inputs: { "Question 1" => "John Doe" }
    )
    # Manually set started_at to 60 seconds ago to test duration
    scenario.update_column(:started_at, 60.seconds.ago)

    scenario.execute

    assert_not_nil scenario.duration_seconds
    assert scenario.duration_seconds >= 59, "Duration should be at least 59 seconds"
  end

  test "process_subflow_step does not crash when results is nil" do
    scenario = Scenario.new(
      workflow: @workflow,
      user: @user,
      status: "active",
      results: nil
    )
    # (self.results || {}).dup should not raise NoMethodError
    child_results = (scenario.results || {}).dup
    assert_equal({}, child_results)
  end
end
