require "test_helper"

class ScenarioExecutionTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "scenario-exec-#{SecureRandom.hex(4)}@example.com", password: "password123456")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def create_workflow(title, status: "published")
    Workflow.create!(title: title, user: @user, status: status)
  end

  def add_question(workflow, title, position:, variable_name: nil, question: "Ask something?")
    Steps::Question.create!(
      workflow: workflow,
      title: title,
      position: position,
      question: question,
      variable_name: variable_name || title.parameterize(separator: "_")
    )
  end

  def add_action(workflow, title, position:)
    Steps::Action.create!(workflow: workflow, title: title, position: position)
  end

  def add_resolve(workflow, title, position:, resolution_type: "success")
    Steps::Resolve.create!(workflow: workflow, title: title, position: position, resolution_type: resolution_type)
  end

  def add_message(workflow, title, position:)
    Steps::Message.create!(workflow: workflow, title: title, position: position)
  end

  def add_subflow(workflow, title, position:, target_workflow:)
    Steps::SubFlow.create!(
      workflow: workflow,
      title: title,
      position: position,
      sub_flow_workflow_id: target_workflow.id
    )
  end

  def link(from_step, to_step, condition: nil, position: 0)
    Transition.create!(step: from_step, target_step: to_step, condition: condition, position: position)
  end

  def build_scenario(workflow, start_step)
    Scenario.create!(
      workflow: workflow,
      user: @user,
      purpose: "simulation",
      status: "active",
      current_node_uuid: start_step.uuid,
      execution_path: [],
      results: {},
      inputs: {}
    )
  end

  # ---------------------------------------------------------------------------
  # Task 19: Sequential execution
  # ---------------------------------------------------------------------------

  test "sequential Q -> A -> Resolve processes to completion" do
    wf = create_workflow("Sequential Flow")
    q  = add_question(wf, "What is the issue?", position: 0)
    a  = add_action(wf, "Check logs", position: 1)
    r  = add_resolve(wf, "Done", position: 2)

    link(q, a)
    link(a, r)
    wf.update!(start_step: q)

    scenario = build_scenario(wf, q)

    # Process question step with an answer
    scenario.process_step("Network down")
    assert_equal a.uuid, scenario.current_node_uuid, "Should advance to action step"

    # Process action step
    scenario.process_step
    assert_equal r.uuid, scenario.current_node_uuid, "Should advance to resolve step"

    # Process resolve step
    scenario.process_step
    assert_predicate scenario, :completed?, "Scenario should be completed after resolve"
    assert_nil scenario.current_node_uuid
    assert_equal "resolved", scenario.outcome
  end

  # ---------------------------------------------------------------------------
  # Task 19: Conditional branching
  # ---------------------------------------------------------------------------

  test "conditional branching follows correct yes/no path" do
    wf = create_workflow("Branching Flow")
    q  = add_question(wf, "Is it urgent?", position: 0, variable_name: "is_urgent")
    yes_step = add_action(wf, "Escalate immediately", position: 1)
    no_step  = add_action(wf, "Schedule follow-up", position: 2)
    resolve  = add_resolve(wf, "Resolved", position: 3)

    link(q, yes_step, condition: "yes", position: 0)
    link(q, no_step, condition: "no", position: 1)
    link(yes_step, resolve)
    link(no_step, resolve)
    wf.update!(start_step: q)

    # Test "yes" path
    scenario_yes = build_scenario(wf, q)
    scenario_yes.process_step("yes")
    assert_equal yes_step.uuid, scenario_yes.current_node_uuid

    # Test "no" path
    scenario_no = build_scenario(wf, q)
    scenario_no.process_step("no")
    assert_equal no_step.uuid, scenario_no.current_node_uuid
  end

  # ---------------------------------------------------------------------------
  # Task 19: Variable capture
  # ---------------------------------------------------------------------------

  test "question step captures answer into results hash" do
    wf = create_workflow("Variable Capture")
    q  = add_question(wf, "Customer Name", position: 0, variable_name: "customer_name")
    r  = add_resolve(wf, "End", position: 1)

    link(q, r)
    wf.update!(start_step: q)

    scenario = build_scenario(wf, q)
    scenario.process_step("Alice Johnson")

    assert_equal "Alice Johnson", scenario.results["customer_name"]
    assert_equal "Alice Johnson", scenario.results["Customer Name"]
  end

  # ---------------------------------------------------------------------------
  # Task 19: Single Resolve step — immediate completion
  # ---------------------------------------------------------------------------

  test "workflow with only a Resolve step completes immediately" do
    wf = create_workflow("Instant Resolve")
    r  = add_resolve(wf, "Auto-resolved", position: 0)
    wf.update!(start_step: r)

    scenario = build_scenario(wf, r)
    scenario.process_step

    assert_predicate scenario, :completed?, "Scenario should be completed"
    assert_equal "resolved", scenario.outcome
    assert_nil scenario.current_node_uuid
  end

  # ---------------------------------------------------------------------------
  # Task 19: Safety limits — circular graph
  # ---------------------------------------------------------------------------

  test "circular graph with question steps eventually hits iteration limit" do
    # Use draft status to bypass graph validation (which rejects cycles)
    wf = create_workflow("Circular", status: "draft")
    # Use question steps — they bypass the idempotency guard (which blocks
    # non-question steps from re-processing when already in execution_path)
    q1 = add_question(wf, "Q1", position: 0, variable_name: "q1")
    q2 = add_question(wf, "Q2", position: 1, variable_name: "q2")

    link(q1, q2)
    link(q2, q1)
    wf.update_column(:start_step_id, q1.id)

    scenario = build_scenario(wf, q1)

    # process_step tracks iteration_count as attr_accessor, reset each call.
    # But it also checks execution_path.length. With a circular graph of
    # question steps, each call adds to execution_path, so eventually
    # iteration_count will exceed MAX_ITERATIONS.
    # MAX_ITERATIONS is 1000 by default — we just need to verify it doesn't hang.
    # Let's call many times and verify it eventually errors.
    error_raised = false
    1100.times do
      begin
        scenario.process_step("answer")
      rescue Scenario::ScenarioIterationLimit
        error_raised = true
        break
      end
      break if scenario.errored?
    end

    assert error_raised || scenario.errored?,
           "Circular graph should eventually hit iteration limit or error status"
  end

  # ---------------------------------------------------------------------------
  # Task 19: Message step auto-advances
  # ---------------------------------------------------------------------------

  test "message step auto-advances to next step" do
    wf = create_workflow("Message Flow")
    m  = add_message(wf, "Welcome!", position: 0)
    r  = add_resolve(wf, "Done", position: 1)

    link(m, r)
    wf.update!(start_step: m)

    scenario = build_scenario(wf, m)
    scenario.process_step

    assert_equal r.uuid, scenario.current_node_uuid
    assert_equal "Message displayed", scenario.results["Welcome!"]
  end

  # ---------------------------------------------------------------------------
  # Task 20: SubFlow spawns child scenario
  # ---------------------------------------------------------------------------

  test "subflow step creates child scenario and marks parent awaiting" do
    child_wf = create_workflow("Child Workflow")
    child_q  = add_question(child_wf, "Child Q", position: 0, variable_name: "child_answer")
    child_r  = add_resolve(child_wf, "Child Done", position: 1)
    link(child_q, child_r)
    child_wf.update!(start_step: child_q)

    parent_wf = create_workflow("Parent Workflow")
    sf = add_subflow(parent_wf, "Run child", position: 0, target_workflow: child_wf)
    parent_r = add_resolve(parent_wf, "Parent Done", position: 1)
    link(sf, parent_r)
    parent_wf.update!(start_step: sf)

    parent_scenario = build_scenario(parent_wf, sf)
    result = parent_scenario.process_step

    assert result, "process_step should return true for subflow"
    assert_predicate parent_scenario, :awaiting_subflow?, "Parent should be awaiting_subflow"
    assert_equal sf.uuid, parent_scenario.resume_node_uuid

    # Child scenario should have been created
    child_scenario = parent_scenario.child_scenarios.first
    assert_not_nil child_scenario, "Child scenario should exist"
    assert_predicate child_scenario, :active?, "Child scenario should be active"
    assert_equal child_wf.id, child_scenario.workflow_id
    assert_equal child_q.uuid, child_scenario.current_node_uuid
  end

  # ---------------------------------------------------------------------------
  # Task 20: SubFlow completion resumes parent
  # ---------------------------------------------------------------------------

  test "completing child scenario resumes parent to next step" do
    child_wf = create_workflow("Child WF")
    child_r  = add_resolve(child_wf, "Child Resolved", position: 0)
    child_wf.update!(start_step: child_r)

    parent_wf = create_workflow("Parent WF")
    sf = add_subflow(parent_wf, "Run child", position: 0, target_workflow: child_wf)
    parent_r = add_resolve(parent_wf, "Parent Resolved", position: 1)
    link(sf, parent_r)
    parent_wf.update!(start_step: sf)

    parent_scenario = build_scenario(parent_wf, sf)
    parent_scenario.process_step # spawns child, parent -> awaiting_subflow

    child_scenario = parent_scenario.child_scenarios.first
    child_scenario.process_step # resolve child

    assert_predicate child_scenario.reload, :completed?, "Child should be completed"

    # Now resume parent
    parent_scenario.reload
    parent_scenario.process_step # should process_subflow_completion

    assert parent_scenario.active? || parent_scenario.completed?,
           "Parent should be active or completed after subflow completion"
    # Parent should have advanced past the subflow step
    assert_not_equal sf.uuid, parent_scenario.current_node_uuid
  end

  # ---------------------------------------------------------------------------
  # Task 20: Nested sub-flows (grandchild)
  # ---------------------------------------------------------------------------

  test "nested subflows: parent -> child -> grandchild does not crash" do
    grandchild_wf = create_workflow("Grandchild WF")
    gc_r = add_resolve(grandchild_wf, "Grandchild Done", position: 0)
    grandchild_wf.update!(start_step: gc_r)

    child_wf = create_workflow("Child WF Nested")
    child_sf = add_subflow(child_wf, "Run grandchild", position: 0, target_workflow: grandchild_wf)
    child_r  = add_resolve(child_wf, "Child Done", position: 1)
    link(child_sf, child_r)
    child_wf.update!(start_step: child_sf)

    parent_wf = create_workflow("Parent WF Nested")
    parent_sf = add_subflow(parent_wf, "Run child", position: 0, target_workflow: child_wf)
    parent_r  = add_resolve(parent_wf, "Parent Done", position: 1)
    link(parent_sf, parent_r)
    parent_wf.update!(start_step: parent_sf)

    # Start parent
    parent_scenario = build_scenario(parent_wf, parent_sf)
    parent_scenario.process_step # spawns child
    assert_predicate parent_scenario, :awaiting_subflow?

    # Child starts with a subflow step -> spawns grandchild
    child_scenario = parent_scenario.child_scenarios.first
    child_scenario.process_step # spawns grandchild
    assert_predicate child_scenario, :awaiting_subflow?

    # Grandchild resolves immediately
    grandchild_scenario = child_scenario.child_scenarios.first
    assert_not_nil grandchild_scenario
    grandchild_scenario.process_step # resolve grandchild
    assert_predicate grandchild_scenario.reload, :completed?

    # Resume child (subflow completion)
    child_scenario.reload
    child_scenario.process_step # process_subflow_completion -> advances to child_r

    # Now process the resolve step in child
    child_scenario.reload
    if child_scenario.active? && child_scenario.current_node_uuid == child_r.uuid
      child_scenario.process_step # resolve child
    end

    assert_predicate child_scenario.reload, :completed?, "Child should be completed"

    # Resume parent
    parent_scenario.reload
    parent_scenario.process_step # process_subflow_completion

    # Process parent resolve if needed
    parent_scenario.reload
    if parent_scenario.active? && parent_scenario.current_node_uuid == parent_r.uuid
      parent_scenario.process_step
    end

    assert_predicate parent_scenario.reload, :completed?, "Parent should be completed after nested subflows"
  end
end
