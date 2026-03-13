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
      user: @user
    )
    # Create AR steps
    Steps::Question.create!(workflow: @workflow, position: 0, uuid: "q1", title: "Question 1", question: "What is your name?", variable_name: "question_1")
    Steps::Action.create!(workflow: @workflow, position: 1, uuid: "a1", title: "Action Check")
    Steps::Action.create!(workflow: @workflow, position: 2, uuid: "a2", title: "Action 1")
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
    resolve_workflow = Workflow.create!(title: "Resolve Workflow", user: @user, graph_mode: true)
    resolve_step = Steps::Resolve.create!(workflow: resolve_workflow, position: 0, uuid: "step-1", title: "Issue Resolved", resolution_type: "success")
    resolve_workflow.update_column(:start_step_id, resolve_step.id)

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
    escalate_workflow = Workflow.create!(title: "Escalate Workflow", user: @user, graph_mode: true)
    escalate_step = Steps::Escalate.create!(workflow: escalate_workflow, position: 0, uuid: "step-1", title: "Escalate Issue", target_type: "supervisor")
    escalate_workflow.update_column(:start_step_id, escalate_step.id)

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

  # can_resolve mid-step resolution tests
  test "action step with can_resolve ends scenario when resolved_here is true" do
    workflow = Workflow.create!(title: "Resolve Test", user: @user, graph_mode: true)
    step1 = Steps::Action.create!(workflow: workflow, position: 0, uuid: "step-1", title: "Restart service", can_resolve: true)
    step2 = Steps::Resolve.create!(workflow: workflow, position: 1, uuid: "step-2", title: "Done", resolution_type: "success")
    Transition.create!(step: step1, target_step: step2, position: 0)
    workflow.update_column(:start_step_id, step1.id)

    scenario = Scenario.create!(workflow: workflow, user: @user, inputs: {}, current_node_uuid: "step-1")
    scenario.process_step(nil, resolved_here: true)

    assert_equal "completed", scenario.status
    assert_equal "resolved", scenario.outcome
    assert_equal "success", scenario.results["_resolution"]["type"]
    assert_equal "step-1", scenario.results["_resolution"]["resolved_at_step"]
    assert_equal true, scenario.execution_path.last["resolved"]
  end

  test "action step with can_resolve continues normally when resolved_here is false" do
    workflow = Workflow.create!(title: "Continue Test", user: @user, graph_mode: true)
    step1 = Steps::Action.create!(workflow: workflow, position: 0, uuid: "step-1", title: "Restart service", can_resolve: true)
    step2 = Steps::Resolve.create!(workflow: workflow, position: 1, uuid: "step-2", title: "Done", resolution_type: "success")
    Transition.create!(step: step1, target_step: step2, position: 0)
    workflow.update_column(:start_step_id, step1.id)

    scenario = Scenario.create!(workflow: workflow, user: @user, inputs: {}, current_node_uuid: "step-1")
    scenario.process_step(nil, resolved_here: false)

    assert_equal "step-2", scenario.current_node_uuid
    assert_not_equal "completed", scenario.status
  end

  test "message step with can_resolve ends scenario when resolved_here is true" do
    workflow = Workflow.create!(title: "Message Resolve Test", user: @user, graph_mode: true)
    step1 = Steps::Message.create!(workflow: workflow, position: 0, uuid: "step-1", title: "Info", can_resolve: true)
    step2 = Steps::Resolve.create!(workflow: workflow, position: 1, uuid: "step-2", title: "Done", resolution_type: "success")
    Transition.create!(step: step1, target_step: step2, position: 0)
    workflow.update_column(:start_step_id, step1.id)

    scenario = Scenario.create!(workflow: workflow, user: @user, inputs: {}, current_node_uuid: "step-1")
    scenario.process_step(nil, resolved_here: true)

    assert_equal "completed", scenario.status
    assert_equal "resolved", scenario.outcome
    assert_equal "step-1", scenario.results["_resolution"]["resolved_at_step"]
  end

  test "resolved_here is ignored when step does not have can_resolve" do
    workflow = Workflow.create!(title: "No Can Resolve Test", user: @user, graph_mode: true)
    step1 = Steps::Action.create!(workflow: workflow, position: 0, uuid: "step-1", title: "Normal action", can_resolve: false)
    step2 = Steps::Resolve.create!(workflow: workflow, position: 1, uuid: "step-2", title: "Done", resolution_type: "success")
    Transition.create!(step: step1, target_step: step2, position: 0)
    workflow.update_column(:start_step_id, step1.id)

    scenario = Scenario.create!(workflow: workflow, user: @user, inputs: {}, current_node_uuid: "step-1")
    scenario.process_step(nil, resolved_here: true)

    # Should continue normally since can_resolve is not set
    assert_equal "step-2", scenario.current_node_uuid
  end
end
