require "test_helper"

# Advancing a run to the next step a user can actually answer.
#
# Some steps are not renderable: a sub_flow starts a child and has no UI, and a
# resolve inside a child scenario exists to hand control back to the parent.
# Both controllers used to auto-process those inside GET step and redirect,
# sometimes more than once. That made GET a mutating request and left the loop
# spread across two shells.
class ScenarioSettlerTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "settler@example.com", password: "password123456")
  end

  # Child: CQ -> CDone
  def child_workflow
    wf = Workflow.create!(title: "Child WF", user: @user)
    cq = Steps::Question.create!(workflow: wf, title: "CQ", position: 0, variable_name: "cv")
    cr = Steps::Resolve.create!(workflow: wf, title: "CDone", position: 1)
    Transition.create!(step: cq, target_step: cr, position: 0)
    wf.update!(start_step: cq)
    [wf, cq]
  end

  test "settling past a sub_flow lands on the child's first answerable step" do
    child_wf, cq = child_workflow

    workflow = Workflow.create!(title: "Parent WF", user: @user)
    sf = Steps::SubFlow.create!(workflow: workflow, title: "SF", position: 0, sub_flow_workflow_id: child_wf.id)
    done = Steps::Resolve.create!(workflow: workflow, title: "Done", position: 1)
    Transition.create!(step: sf, target_step: done, position: 0)
    workflow.update!(start_step: sf)

    scenario = Scenario.create!(
      workflow: workflow, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: sf.uuid, execution_path: [], results: {}, inputs: {}
    )

    settled = ScenarioSettler.new(scenario).settle

    assert_equal cq.uuid, settled.scenario.current_node_uuid,
                 "the run lives on the child now"
    assert_not_equal scenario, settled.scenario,
                     "and the leaf is a different scenario from the one we started on"
  end
  test "settling a child's last answer climbs back to the parent's next step" do
    child_wf, cq = child_workflow

    workflow = Workflow.create!(title: "Parent WF", user: @user)
    sf = Steps::SubFlow.create!(workflow: workflow, title: "SF", position: 0, sub_flow_workflow_id: child_wf.id)
    after = Steps::Question.create!(workflow: workflow, title: "After", position: 1, variable_name: "av")
    done = Steps::Resolve.create!(workflow: workflow, title: "Done", position: 2)
    Transition.create!(step: sf, target_step: after, position: 0)
    Transition.create!(step: after, target_step: done, position: 0)
    workflow.update!(start_step: sf)

    scenario = Scenario.create!(
      workflow: workflow, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: sf.uuid, execution_path: [], results: {}, inputs: {}
    )
    child = ScenarioSettler.new(scenario).settle.scenario
    assert_equal cq.uuid, child.current_node_uuid, "precondition: we are in the child"

    settled = ScenarioSettler.new(child).settle("ChildAnswer")

    assert_equal after.uuid, settled.scenario.current_node_uuid,
                 "the child's resolve is the sub-flow ending, not the run ending"
    assert_equal scenario.id, settled.scenario.id, "and the run is back on the parent"
  end

  test "settling climbs out of nested sub-flows in one move" do
    inner_wf, _iq = child_workflow

    middle_wf = Workflow.create!(title: "Middle WF", user: @user)
    msf = Steps::SubFlow.create!(workflow: middle_wf, title: "MSF", position: 0, sub_flow_workflow_id: inner_wf.id)
    mdone = Steps::Resolve.create!(workflow: middle_wf, title: "MDone", position: 1)
    Transition.create!(step: msf, target_step: mdone, position: 0)
    middle_wf.update!(start_step: msf)

    workflow = Workflow.create!(title: "Outer WF", user: @user)
    sf = Steps::SubFlow.create!(workflow: workflow, title: "SF", position: 0, sub_flow_workflow_id: middle_wf.id)
    after = Steps::Question.create!(workflow: workflow, title: "After", position: 1, variable_name: "av")
    done = Steps::Resolve.create!(workflow: workflow, title: "Done", position: 2)
    Transition.create!(step: sf, target_step: after, position: 0)
    Transition.create!(step: after, target_step: done, position: 0)
    workflow.update!(start_step: sf)

    scenario = Scenario.create!(
      workflow: workflow, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: sf.uuid, execution_path: [], results: {}, inputs: {}
    )
    innermost = ScenarioSettler.new(scenario).settle.scenario

    settled = ScenarioSettler.new(innermost).settle("Answer")

    assert_equal after.uuid, settled.scenario.current_node_uuid,
                 "two sub-flows closing at once is still one settle"
    assert_equal scenario.id, settled.scenario.id
  end

  test "a refused step settles where the user already is" do
    workflow = Workflow.create!(title: "Blocking WF", user: @user)
    esc = Steps::Escalate.create!(
      workflow: workflow, title: "Escalate", position: 0,
      target_type: "supervisor", reason_required: true
    )
    done = Steps::Resolve.create!(workflow: workflow, title: "Done", position: 1)
    Transition.create!(step: esc, target_step: done, position: 0)
    workflow.update!(start_step: esc)

    scenario = Scenario.create!(
      workflow: workflow, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: esc.uuid, execution_path: [], results: {}, inputs: {}
    )

    settled = ScenarioSettler.new(scenario).settle(nil)

    assert_predicate settled, :blocked?
    assert_equal esc.uuid, settled.scenario.current_node_uuid, "a refusal does not move the run"
    assert_empty settled.traversed, "and appends nothing to the transcript"
  end

  test "traversed carries a row for every step processed on the way" do
    child_wf, = child_workflow

    workflow = Workflow.create!(title: "Parent WF", user: @user)
    sf = Steps::SubFlow.create!(workflow: workflow, title: "SF", position: 0, sub_flow_workflow_id: child_wf.id)
    done = Steps::Resolve.create!(workflow: workflow, title: "Done", position: 1)
    Transition.create!(step: sf, target_step: done, position: 0)
    workflow.update!(start_step: sf)

    scenario = Scenario.create!(
      workflow: workflow, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: sf.uuid, execution_path: [], results: {}, inputs: {}
    )

    settled = ScenarioSettler.new(scenario).settle

    assert_equal ["sub_flow"], settled.traversed.pluck("step_type"),
                 "the sub_flow step the user never saw still belongs in the transcript"
  end

  test "settling the last step of a top-level run reports it resolved" do
    workflow = Workflow.create!(title: "Short WF", user: @user)
    q = Steps::Question.create!(workflow: workflow, title: "Q", position: 0, variable_name: "qv")
    done = Steps::Resolve.create!(workflow: workflow, title: "Done", position: 1)
    Transition.create!(step: q, target_step: done, position: 0)
    workflow.update!(start_step: q)

    scenario = Scenario.create!(
      workflow: workflow, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: q.uuid, execution_path: [], results: {}, inputs: {}
    )
    ScenarioSettler.new(scenario).settle("Yes")

    settled = ScenarioSettler.new(scenario).settle(nil)

    assert_predicate settled, :resolved?
    assert_equal scenario.id, settled.scenario.id, "a top-level resolve has nowhere to climb to"
  end
end
