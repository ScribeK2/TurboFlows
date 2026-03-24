require "test_helper"

class ScenarioGraphExecutionTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(
      email: "graph_exec_#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
  end

  # ---------------------------------------------------------------------------
  # 1. Executes through graph-mode workflow following unconditional transitions
  # ---------------------------------------------------------------------------
  test "executes through graph-mode workflow following unconditional transitions" do
    wf = Workflow.create!(title: "Linear Chain", user: @user, graph_mode: true, status: "published")
    q  = Steps::Question.create!(workflow: wf, position: 0, title: "Q1", question: "Name?", variable_name: "name")
    a  = Steps::Action.create!(workflow: wf, position: 1, title: "Greet")
    r  = Steps::Resolve.create!(workflow: wf, position: 2, title: "Done", resolution_type: "success")

    Transition.create!(step: q, target_step: a, position: 0)
    Transition.create!(step: a, target_step: r, position: 0)
    wf.update_column(:start_step_id, q.id)

    scenario = Scenario.create!(
      workflow: wf,
      user: @user,
      current_node_uuid: q.uuid,
      inputs: {},
      purpose: "simulation"
    )

    # Step 1: question
    scenario.process_step("Alice")
    scenario.reload
    assert_equal a.uuid, scenario.current_node_uuid, "Should advance to action step after question"

    # Step 2: action
    scenario.process_step
    scenario.reload
    assert_equal r.uuid, scenario.current_node_uuid, "Should advance to resolve step after action"

    # Step 3: resolve (terminal)
    scenario.process_step
    scenario.reload
    assert_equal "completed", scenario.status
    assert_equal "resolved",  scenario.outcome
  end

  # ---------------------------------------------------------------------------
  # 2. Conditional transitions route based on input values
  # ---------------------------------------------------------------------------
  test "conditional transitions route based on input values" do
    wf  = Workflow.create!(title: "Branch Workflow", user: @user, graph_mode: true, status: "published")
    q   = Steps::Question.create!(workflow: wf, position: 0, title: "Choice", question: "Yes or no?", variable_name: "choice")
    yes = Steps::Resolve.create!(workflow: wf, position: 1, title: "Yes Path", resolution_type: "success")
    no  = Steps::Resolve.create!(workflow: wf, position: 2, title: "No Path",  resolution_type: "success")

    Transition.create!(step: q, target_step: yes, condition: "choice == 'yes'", position: 0)
    Transition.create!(step: q, target_step: no,  condition: "choice == 'no'",  position: 1)
    wf.update_column(:start_step_id, q.id)

    scenario = Scenario.create!(
      workflow: wf,
      user: @user,
      current_node_uuid: q.uuid,
      inputs: {},
      purpose: "simulation"
    )

    scenario.process_step("yes")
    scenario.reload

    assert_equal yes.uuid, scenario.current_node_uuid,
                 "Should route to Yes Path when answer is 'yes'"
  end

  # ---------------------------------------------------------------------------
  # 3. Terminal resolve step completes scenario with resolution metadata
  # ---------------------------------------------------------------------------
  test "terminal resolve step completes scenario with resolution metadata" do
    wf = Workflow.create!(title: "Resolve Only", user: @user, graph_mode: true, status: "published")
    r  = Steps::Resolve.create!(workflow: wf, position: 0, title: "Issue Resolved",
                                resolution_type: "success", resolution_code: "RES-001")
    wf.update_column(:start_step_id, r.id)

    scenario = Scenario.create!(
      workflow: wf,
      user: @user,
      current_node_uuid: r.uuid,
      inputs: {},
      purpose: "simulation"
    )

    scenario.process_step
    scenario.reload

    assert_equal "completed", scenario.status
    assert_equal "resolved",  scenario.outcome
    assert_not_nil scenario.results["_resolution"], "Should have _resolution metadata in results"
    assert_equal "success",   scenario.results["_resolution"]["type"]
    assert_equal "RES-001",   scenario.results["_resolution"]["code"]
    assert_nil   scenario.current_node_uuid, "current_node_uuid should be nil after terminal resolve"
  end

  # ---------------------------------------------------------------------------
  # 4. Sub-flow step creates child scenario and sets parent to awaiting_subflow
  # ---------------------------------------------------------------------------
  test "subflow step creates child scenario and sets parent to awaiting_subflow" do
    child_wf = Workflow.create!(title: "Child WF", user: @user, graph_mode: true, status: "published")
    child_r  = Steps::Resolve.create!(workflow: child_wf, position: 0, title: "Child Done", resolution_type: "success")
    child_wf.update_column(:start_step_id, child_r.id)

    parent_wf = Workflow.create!(title: "Parent WF", user: @user, graph_mode: true, status: "published")
    sf = Steps::SubFlow.create!(workflow: parent_wf, position: 0, title: "Run Sub-flow",
                                sub_flow_workflow_id: child_wf.id)
    parent_r = Steps::Resolve.create!(workflow: parent_wf, position: 1, title: "Parent Done", resolution_type: "success")
    Transition.create!(step: sf, target_step: parent_r, position: 0)
    parent_wf.update_column(:start_step_id, sf.id)

    parent_scenario = Scenario.create!(
      workflow: parent_wf,
      user: @user,
      current_node_uuid: sf.uuid,
      inputs: {},
      purpose: "simulation"
    )

    parent_scenario.process_step
    parent_scenario.reload

    assert_equal "awaiting_subflow", parent_scenario.status,
                 "Parent should be awaiting_subflow after processing sub-flow step"

    child = parent_scenario.child_scenarios.first
    assert_not_nil child, "A child scenario should have been created"
    assert_equal child_wf.id, child.workflow_id, "Child scenario should use the target workflow"
    assert_equal parent_scenario.id, child.parent_scenario_id
  end

  # ---------------------------------------------------------------------------
  # 5. process_subflow_completion resumes parent scenario
  # ---------------------------------------------------------------------------
  test "process_subflow_completion resumes parent scenario after child completes" do
    child_wf = Workflow.create!(title: "Child WF Resume", user: @user, graph_mode: true, status: "published")
    child_r  = Steps::Resolve.create!(workflow: child_wf, position: 0, title: "Child Done", resolution_type: "success")
    child_wf.update_column(:start_step_id, child_r.id)

    parent_wf = Workflow.create!(title: "Parent WF Resume", user: @user, graph_mode: true, status: "published")
    sf       = Steps::SubFlow.create!(workflow: parent_wf, position: 0, title: "Run Sub-flow",
                                      sub_flow_workflow_id: child_wf.id)
    parent_r = Steps::Resolve.create!(workflow: parent_wf, position: 1, title: "Parent Done", resolution_type: "success")
    Transition.create!(step: sf, target_step: parent_r, position: 0)
    parent_wf.update_column(:start_step_id, sf.id)

    parent_scenario = Scenario.create!(
      workflow: parent_wf,
      user: @user,
      current_node_uuid: sf.uuid,
      inputs: {},
      purpose: "simulation"
    )

    # Trigger sub-flow step — parent becomes awaiting_subflow
    parent_scenario.process_step
    parent_scenario.reload

    assert_equal "awaiting_subflow", parent_scenario.status

    # Complete the child scenario manually
    child = parent_scenario.child_scenarios.first
    assert_not_nil child

    child.update!(status: "completed", outcome: "completed")

    # Resume parent
    result = parent_scenario.process_subflow_completion
    parent_scenario.reload

    assert result, "process_subflow_completion should return true"
    assert_equal "active", parent_scenario.status,
                 "Parent should become active again (or completed) after resumption"
    # Parent should have advanced past the sub-flow step
    assert_not_equal sf.uuid, parent_scenario.current_node_uuid,
                     "Parent should have moved past the sub-flow step"
  end

  # ---------------------------------------------------------------------------
  # 6. check_jumps navigates to jump target
  # ---------------------------------------------------------------------------
  test "check_jumps returns correct position when jump condition matches" do
    wf    = Workflow.create!(title: "Jump Workflow", user: @user, graph_mode: false, status: "published")
    step1 = Steps::Question.create!(
      workflow: wf, position: 0, title: "Q Jump", question: "Jump?", variable_name: "action",
      jumps: [{ "condition" => "skip", "next_step_id" => nil }] # placeholder, will fill with uuid below
    )
    step3 = Steps::Action.create!(workflow: wf, position: 2, title: "Jump Target")
    _step2 = Steps::Action.create!(workflow: wf, position: 1, title: "Middle Step")

    # Update the jump to reference step3's uuid
    step1.update!(jumps: [{ "condition" => "skip", "next_step_id" => step3.uuid }])

    scenario = Scenario.create!(
      workflow: wf,
      user: @user,
      current_step_index: 0,
      inputs: {},
      purpose: "simulation"
    )

    results = { "Q Jump" => "skip", "action" => "skip" }
    jumped_position = scenario.check_jumps(step1, results)

    assert_equal step3.position, jumped_position,
                 "check_jumps should return position of jump target when condition matches"
  end

  # ---------------------------------------------------------------------------
  # 7. Scenario timeout on execute
  # ---------------------------------------------------------------------------
  test "scenario execute returns false and sets timed_out status on timeout" do
    wf = Workflow.create!(title: "Timeout Workflow", user: @user, status: "published")
    Steps::Question.create!(workflow: wf, position: 0, title: "Q1", question: "?", variable_name: "q1")

    scenario = Scenario.create!(
      workflow: wf,
      user: @user,
      inputs: { "q1" => "value" },
      purpose: "simulation"
    )

    # Simulate timeout by temporarily defining a singleton method that raises ScenarioTimeout.
    # This mirrors what Timeout.timeout raises when MAX_EXECUTION_TIME is exceeded,
    # which is exactly what `execute` rescues and converts to a timed_out status.
    scenario.define_singleton_method(:execute_with_limits) do
      raise Scenario::ScenarioTimeout, "forced timeout"
    end

    result = scenario.execute
    assert_not result, "execute should return false on timeout"

    scenario.reload
    assert_equal "timed_out", scenario.status, "Status should be timed_out after timeout"
    assert_equal "timeout",   scenario.status_before_type_cast, "Raw DB value should be 'timeout'"
    assert_predicate scenario.results["_error"], :present?
  end

  # ---------------------------------------------------------------------------
  # 8. Graph mode execution path tracks step UUIDs
  # ---------------------------------------------------------------------------
  test "graph mode execution path entries contain step_uuid key" do
    wf = Workflow.create!(title: "Path Tracking WF", user: @user, graph_mode: true, status: "published")
    q  = Steps::Question.create!(workflow: wf, position: 0, title: "Track Q", question: "?", variable_name: "track")
    r  = Steps::Resolve.create!(workflow: wf, position: 1, title: "End", resolution_type: "success")
    Transition.create!(step: q, target_step: r, position: 0)
    wf.update_column(:start_step_id, q.id)

    scenario = Scenario.create!(
      workflow: wf,
      user: @user,
      current_node_uuid: q.uuid,
      inputs: {},
      purpose: "simulation"
    )

    scenario.process_step("hello")
    scenario.reload

    assert_predicate scenario.execution_path, :any?, "Execution path should not be empty"
    first_entry = scenario.execution_path.first
    assert first_entry.key?("step_uuid") || first_entry.key?(:step_uuid),
           "Graph mode execution path entry should have a step_uuid key (got keys: #{first_entry.keys.inspect})"
    uuid_value = first_entry["step_uuid"] || first_entry[:step_uuid]
    assert_equal q.uuid, uuid_value, "step_uuid should match the processed step's UUID"
  end
end
