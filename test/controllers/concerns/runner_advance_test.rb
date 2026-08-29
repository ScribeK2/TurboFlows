require "test_helper"

# The runner's advance seam, exercised over HTTP through ScenariosController.
#
# Replaces SubflowOrchestrationTest. Most of those tests asserted that GET step
# auto-processed sub-flow steps and resumed finished children — a read that
# moved the run. ScenarioSettler does that work on POST now, so the cases are
# rewritten rather than deleted: the sub-flow behaviour they covered still has
# to hold, it just happens somewhere else.
class RunnerAdvanceTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      email: "runner-advance-#{SecureRandom.hex(4)}@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    sign_in @user

    @child_wf = Workflow.create!(title: "Child WF", user: @user, status: "published")
    @child_q = Steps::Question.create!(
      workflow: @child_wf, title: "Child Q", position: 0,
      variable_name: "child_answer", question: "Child question?"
    )
    @child_r = Steps::Resolve.create!(
      workflow: @child_wf, title: "Child Done", position: 1, resolution_type: "success"
    )
    Transition.create!(step: @child_q, target_step: @child_r, position: 0)
    @child_wf.update!(start_step: @child_q)

    @parent_wf = Workflow.create!(title: "Parent WF", user: @user, status: "published")
    @subflow_step = Steps::SubFlow.create!(
      workflow: @parent_wf, title: "Run child", position: 0,
      sub_flow_workflow_id: @child_wf.id
    )
    @parent_r = Steps::Resolve.create!(
      workflow: @parent_wf, title: "Parent Done", position: 1, resolution_type: "success"
    )
    Transition.create!(step: @subflow_step, target_step: @parent_r, position: 0)
    @parent_wf.update!(start_step: @subflow_step)
  end

  def parent_scenario
    Scenario.create!(
      workflow: @parent_wf, user: @user, purpose: "simulation",
      status: "active", current_node_uuid: @subflow_step.uuid,
      execution_path: [], results: {}, inputs: {}
    )
  end

  test "step redirects to the child while the child is still running" do
    parent = parent_scenario
    parent.process_step
    child = parent.child_scenarios.first

    get step_scenario_path(parent)

    assert_redirected_to step_scenario_path(child)
  end

  test "step does not resume a finished child" do
    parent = parent_scenario
    parent.process_step
    child = parent.child_scenarios.first
    child.process_step("answer")
    child.reload.process_step
    assert_predicate child.reload, :completed?

    get step_scenario_path(parent)

    assert_response :success
    assert_equal "awaiting_subflow", parent.reload.status,
                 "a read must not move the run — resuming is POST work"
  end

  test "posting to a parked run resumes it" do
    parent = parent_scenario
    parent.process_step
    child = parent.child_scenarios.first
    child.process_step("answer")
    child.reload.process_step
    assert_predicate parent.reload, :parked?, "precondition"

    post next_step_scenario_path(parent)

    parent.reload
    assert_not_equal "awaiting_subflow", parent.status
    assert_not_predicate parent, :parked?
  end

  test "answering a step that opens a sub_flow lands on the child's first question" do
    pre = Steps::Question.create!(
      workflow: @parent_wf, title: "Pre Q", position: 0,
      variable_name: "pre_q", question: "Before subflow?"
    )
    @subflow_step.update!(position: 1)
    @parent_r.update!(position: 2)
    Transition.create!(step: pre, target_step: @subflow_step, position: 0)
    @parent_wf.update!(start_step: pre)

    parent = Scenario.create!(
      workflow: @parent_wf, user: @user, purpose: "simulation",
      status: "active", current_node_uuid: pre.uuid,
      execution_path: [], results: {}, inputs: {}
    )

    post next_step_scenario_path(parent), params: { answer: "yes" }

    child = parent.reload.active_child_scenario
    assert_predicate child, :present?, "the sub_flow should have spawned a child"
    assert_response :success, "the answer is streamed onto the page, not redirected away from"
    assert_match(/Child Q/, response.body, "the child's first question is the card now open")
    assert_equal @child_q.uuid, child.current_node_uuid,
                 "one POST crosses the sub_flow node and stops at something answerable"
  end

  test "answering a child's last step climbs back to the parent" do
    parent = parent_scenario
    parent.process_step
    child = parent.child_scenarios.first

    post next_step_scenario_path(child), params: { answer: "answer" }

    parent.reload
    assert_equal @parent_r.uuid, parent.current_node_uuid,
                 "the child's resolve ends the sub-flow, not the run"
    assert_response :success, "climbing back out streams, it does not redirect"
    assert_not_predicate parent, :awaiting_subflow?
  end

  test "a top-level resolve is not auto-processed" do
    parent = parent_scenario
    parent.process_step
    child = parent.child_scenarios.first

    post next_step_scenario_path(child), params: { answer: "answer" }

    assert_equal "active", parent.reload.status,
                 "the run stops on its own Resolve so the agent can acknowledge it — " \
                 "only a resolve inside a child is the engine talking to itself"
  end

  test "starting a workflow whose first step is a sub_flow opens on the child" do
    post workflow_execution_path(@parent_wf)

    scenario = Scenario.where(workflow: @child_wf).order(:id).last
    assert_predicate scenario, :present?, "creation should have settled into the child"
    assert_redirected_to step_scenario_path(scenario)
  end
  # Replaces "completed child scenario in step action triggers parent
  # advancement", which the old concern satisfied by resuming the parent inside
  # the GET. A read cannot do that any more, but sending the user to the results
  # page for a run that is still going is not the answer either.
  test "step on a completed child goes to the parent, not to results" do
    parent = parent_scenario
    parent.process_step
    child = parent.child_scenarios.first
    child.process_step("answer")
    child.reload.process_step
    assert_predicate child.reload, :complete?, "precondition"
    assert_not_predicate parent.reload, :complete?, "precondition: the run is not over"

    get step_scenario_path(child)

    assert_redirected_to step_scenario_path(parent)
  end
  # The plan's named regression: "GET step performs zero writes — the only thing
  # that keeps purity true as people add code to that action." Deliberately a
  # blanket assertion rather than a check of particular fields, because the
  # point is to catch the *next* write, not the ones removed here.
  test "step writes nothing, on every branch it can take" do
    # 1. an ordinary answerable step
    plain_wf = Workflow.create!(title: "Plain WF", user: @user)
    q = Steps::Question.create!(workflow: plain_wf, position: 0, uuid: SecureRandom.uuid,
                                title: "Q", question: "Q?", variable_name: "qv")
    r = Steps::Resolve.create!(workflow: plain_wf, position: 1, uuid: SecureRandom.uuid, title: "Done")
    Transition.create!(step: q, target_step: r, position: 0)
    plain_wf.update!(start_step: q)
    plain = Scenario.create!(
      workflow: plain_wf, user: @user, purpose: "simulation", status: "active",
      current_node_uuid: q.uuid, execution_path: [], results: {}, inputs: {}
    )

    # 2. a parent whose child is still running (redirect branch)
    waiting = parent_scenario
    waiting.process_step
    running_child = waiting.child_scenarios.first

    # 3. a parent whose child has finished (parked branch)
    stuck = parent_scenario
    stuck.process_step
    finished_child = stuck.child_scenarios.first
    finished_child.process_step("answer")
    finished_child.reload.process_step

    [plain, waiting, stuck, running_child].each do |scenario|
      scenario.reload
      before = scenario.attributes

      get step_scenario_path(scenario)

      assert_equal before, scenario.reload.attributes,
                   "GET step changed #{scenario.id}: a read must not move the run"
    end
  end
end
