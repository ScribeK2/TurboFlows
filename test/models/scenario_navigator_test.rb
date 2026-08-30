require "test_helper"

# Rewinding a run one step.
#
# These drive real runs through process_step rather than hand-building
# execution_path entries. The old versions of several of these tests built
# entries by hand and passed trivially: without an undo log the navigator now
# declines to move, and "nothing happened" satisfied assertions that were meant
# to prove something did.
class ScenarioNavigatorTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "nav-test@example.com", password: "password123456")
  end

  # Action(writes ticket_id) -> Q1 -> Q2 -> Resolve
  def build_run
    workflow = Workflow.create!(title: "Nav WF", user: @user)
    action = Steps::Action.create!(
      workflow: workflow, title: "Look up account", position: 0,
      output_fields: [{ "name" => "ticket_id", "value" => "T-42" }]
    )
    q1 = Steps::Question.create!(workflow: workflow, title: "Q1", position: 1, variable_name: "q1_var")
    q2 = Steps::Question.create!(workflow: workflow, title: "Q2", position: 2, variable_name: "q2_var")
    resolve = Steps::Resolve.create!(workflow: workflow, title: "Done", position: 3)
    Transition.create!(step: action, target_step: q1, position: 0)
    Transition.create!(step: q1, target_step: q2, position: 0)
    Transition.create!(step: q2, target_step: resolve, position: 0)
    workflow.update!(start_step: action)

    scenario = Scenario.create!(
      workflow: workflow, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: action.uuid, execution_path: [], results: {}, inputs: {}
    )
    [scenario, { action: action, q1: q1, q2: q2, resolve: resolve }]
  end

  test "go_back returns to the step that was just answered" do
    scenario, steps = build_run
    scenario.process_step(nil)
    scenario.process_step("Yes")

    ScenarioNavigator.new(scenario).go_back

    assert_equal steps[:q1].uuid, scenario.current_node_uuid
  end

  test "go_back undoes the answer of the step it pops" do
    scenario, = build_run
    scenario.process_step(nil)
    scenario.process_step("Yes")

    ScenarioNavigator.new(scenario).go_back

    assert_not scenario.results.key?("q1_var")
    assert_not scenario.inputs.key?("q1_var")
  end

  test "go_back restores results written by a non-question step" do
    scenario, = build_run
    scenario.process_step(nil)   # action writes ticket_id
    scenario.process_step("Yes") # question

    ScenarioNavigator.new(scenario).go_back

    assert_equal "T-42", scenario.results["ticket_id"],
                 "backing out of the question must not discard what the action wrote"
  end

  test "go_back keeps the answer of a question it did not pop" do
    scenario, = build_run
    scenario.process_step(nil)
    scenario.process_step("Yes")  # Q1
    scenario.process_step("No")   # Q2

    ScenarioNavigator.new(scenario).go_back

    assert_equal "Yes", scenario.results["q1_var"]
    assert_not scenario.results.key?("q2_var")
  end

  test "go_back reopens a run that had completed" do
    scenario, = build_run
    scenario.process_step(nil)
    scenario.process_step("Yes")
    scenario.process_step("No")
    scenario.process_step(nil) # resolve
    assert_equal "completed", scenario.status

    ScenarioNavigator.new(scenario).go_back

    assert_equal "active", scenario.reload.status
  end

  test "go_back does nothing when the execution path is empty" do
    scenario, steps = build_run

    ScenarioNavigator.new(scenario).go_back

    assert_equal steps[:action].uuid, scenario.current_node_uuid
  end

  # Runs started before entries carried an undo log. Their non-question results
  # are not recoverable, and the rebuild this replaced destroyed them silently.
  test "go_back is refused for a run whose entries predate the undo log" do
    scenario, steps = build_run
    scenario.update!(
      current_node_uuid: steps[:q1].uuid,
      execution_path: [
        { "step_title" => "Look up account", "step_type" => "action", "step_uuid" => steps[:action].uuid }
      ],
      results: { "ticket_id" => "T-42" }
    )
    navigator = ScenarioNavigator.new(scenario)

    assert_not navigator.can_go_back?
    navigator.go_back

    assert_equal steps[:q1].uuid, scenario.current_node_uuid, "the run must not move"
    assert_equal "T-42", scenario.results["ticket_id"], "and must not lose anything"
  end

  test "escalate consumes its reason so a later step cannot reuse it" do
    workflow = Workflow.create!(title: "Escalate WF", user: @user)
    escalate = Steps::Escalate.create!(
      workflow: workflow, title: "Escalate", position: 0,
      target_type: "supervisor", reason_required: true
    )
    resolve = Steps::Resolve.create!(workflow: workflow, title: "Done", position: 1)
    Transition.create!(step: escalate, target_step: resolve, position: 0)
    workflow.update!(start_step: escalate)

    scenario = Scenario.create!(
      workflow: workflow, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: escalate.uuid, execution_path: [], results: {}, inputs: {}
    )
    scenario.inputs["escalation_reason"] = "Customer irate"
    scenario.process_step(nil)

    assert_nil scenario.inputs["escalation_reason"]
    assert_equal "Customer irate", scenario.results.dig("_escalation", "reason"),
                 "consumed, not discarded"
  end

  test "go_back does not resurrect a consumed escalation reason" do
    workflow = Workflow.create!(title: "Escalate WF", user: @user)
    question = Steps::Question.create!(workflow: workflow, title: "Q", position: 0, variable_name: "qv")
    escalate = Steps::Escalate.create!(
      workflow: workflow, title: "Escalate", position: 1,
      target_type: "supervisor", reason_required: true
    )
    resolve = Steps::Resolve.create!(workflow: workflow, title: "Done", position: 2)
    Transition.create!(step: question, target_step: escalate, position: 0)
    Transition.create!(step: escalate, target_step: resolve, position: 0)
    workflow.update!(start_step: question)

    scenario = Scenario.create!(
      workflow: workflow, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: question.uuid, execution_path: [], results: {}, inputs: {}
    )
    scenario.process_step("Yes")
    scenario.inputs["escalation_reason"] = "Customer irate"
    scenario.process_step(nil)

    ScenarioNavigator.new(scenario).go_back

    assert_nil scenario.inputs["escalation_reason"],
               "a required reason must not be satisfied by a value spent on an abandoned attempt"
  end
  test "go_back past a sub_flow stops the child and releases the parent" do
    child_wf = Workflow.create!(title: "Child WF", user: @user)
    cq = Steps::Question.create!(workflow: child_wf, title: "CQ", position: 0, variable_name: "cv")
    cr = Steps::Resolve.create!(workflow: child_wf, title: "CDone", position: 1)
    Transition.create!(step: cq, target_step: cr, position: 0)
    child_wf.update!(start_step: cq)

    workflow = Workflow.create!(title: "Parent WF", user: @user)
    q1 = Steps::Question.create!(workflow: workflow, title: "Q1", position: 0, variable_name: "q1_var")
    sf = Steps::SubFlow.create!(workflow: workflow, title: "SF", position: 1, sub_flow_workflow_id: child_wf.id)
    done = Steps::Resolve.create!(workflow: workflow, title: "Done", position: 2)
    Transition.create!(step: q1, target_step: sf, position: 0)
    Transition.create!(step: sf, target_step: done, position: 0)
    workflow.update!(start_step: q1)

    scenario = Scenario.create!(
      workflow: workflow, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: q1.uuid, execution_path: [], results: {}, inputs: {}
    )
    scenario.process_step("Yes")
    scenario.process_step(nil) # enters the sub-flow
    child = scenario.child_scenarios.first

    assert_equal "awaiting_subflow", scenario.status, "precondition"
    assert_equal "active", child.status, "precondition"

    ScenarioNavigator.new(scenario).go_back

    assert_equal "stopped", child.reload.status,
                 "an abandoned sub-flow must not leave a running child behind"
    assert_equal "active", scenario.status,
                 "the parent must not stay parked on a child its path no longer references"
    assert_equal q1.uuid, scenario.current_node_uuid
  end
  test "go_back past a terminal step clears the outcome it recorded" do
    scenario, = build_run
    scenario.process_step(nil)
    scenario.process_step("Yes")
    scenario.process_step("No")
    scenario.process_step(nil) # resolve
    assert scenario.results.key?("_resolution"), "precondition"

    ScenarioNavigator.new(scenario).go_back

    assert_not scenario.results.key?("_resolution"),
               "a reopened run still claiming a resolution reports the wrong outcome: " \
               "scenario_summary_sentence checks _resolution before _escalation"
  end
  test "go_back past a completed sub_flow undoes what the child merged in" do
    child_wf = Workflow.create!(title: "Child WF", user: @user)
    cq = Steps::Question.create!(workflow: child_wf, title: "CQ", position: 0, variable_name: "cv")
    cr = Steps::Resolve.create!(workflow: child_wf, title: "CDone", position: 1)
    Transition.create!(step: cq, target_step: cr, position: 0)
    child_wf.update!(start_step: cq)

    workflow = Workflow.create!(title: "Parent WF", user: @user)
    q1 = Steps::Question.create!(workflow: workflow, title: "Q1", position: 0, variable_name: "q1v")
    sf = Steps::SubFlow.create!(workflow: workflow, title: "SF", position: 1, sub_flow_workflow_id: child_wf.id)
    q2 = Steps::Question.create!(workflow: workflow, title: "Q2", position: 2, variable_name: "q2v")
    done = Steps::Resolve.create!(workflow: workflow, title: "Done", position: 3)
    Transition.create!(step: q1, target_step: sf, position: 0)
    Transition.create!(step: sf, target_step: q2, position: 0)
    Transition.create!(step: q2, target_step: done, position: 0)
    workflow.update!(start_step: q1)

    scenario = Scenario.create!(
      workflow: workflow, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: q1.uuid, execution_path: [], results: {}, inputs: {}
    )
    scenario.process_step("Yes")
    scenario.process_step(nil)             # enter the sub-flow
    child = scenario.child_scenarios.first
    child.process_step("ChildAnswer")      # CQ
    child.process_step(nil)                # child resolve
    scenario.reload.process_subflow_completion
    scenario.process_step("No")            # Q2, back in the parent

    assert_equal "ChildAnswer", scenario.results["cv"], "precondition: the child's value was merged in"

    navigator = ScenarioNavigator.new(scenario)
    navigator.go_back                      # pops Q2
    navigator.go_back                      # pops the sub_flow region

    assert_not scenario.results.key?("cv"),
               "the child's contribution belongs to the sub_flow step and must be undone with it"
    assert_not scenario.results.key?("CQ")
  end
end
