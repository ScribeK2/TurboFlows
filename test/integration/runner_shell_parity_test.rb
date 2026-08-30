require "test_helper"

# The two runner shells answering the same questions the same way.
#
# `RunnerShell` unified the POST half of the runner — how far an answer moves
# the run, and what the response says. The GET half was still written twice, and
# had drifted: five decisions about the *same* run had two answers depending on
# which URL the agent happened to be at. Each test here names one of them, and
# asserts the answer both shells now give.
#
# The discriminating principle in every case is the one already written into
# both #stop actions: report on the run the user started, not the sub-flow frame
# they happen to be standing in.
class RunnerShellParityTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      email: "parity-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    sign_in @user

    @child_wf = Workflow.create!(title: "Child Workflow", user: @user, status: "published")
    @child_q = Steps::Question.create!(workflow: @child_wf, position: 0, title: "Child Question",
                                       question: "Child?", variable_name: "cv")
    @child_resolve = Steps::Resolve.create!(workflow: @child_wf, position: 1, title: "Child Done",
                                            resolution_type: "success")
    Transition.create!(step: @child_q, target_step: @child_resolve, position: 0)
    @child_wf.update!(start_step: @child_q)

    @root_wf = Workflow.create!(title: "Root Workflow", user: @user, status: "published")
    @q = Steps::Question.create!(workflow: @root_wf, position: 0, title: "Root Question",
                                 question: "Root?", variable_name: "rv")
    @sf = Steps::SubFlow.create!(workflow: @root_wf, position: 1, title: "Into the sub-flow",
                                 sub_flow_workflow_id: @child_wf.id)
    @resolve = Steps::Resolve.create!(workflow: @root_wf, position: 2, title: "Root Done",
                                      resolution_type: "success")
    Transition.create!(step: @q, target_step: @sf, position: 0)
    Transition.create!(step: @sf, target_step: @resolve, position: 0)
    @root_wf.update!(start_step: @q)
  end

  def scenario_at(step, workflow: @root_wf)
    Scenario.create!(
      workflow: workflow, user: @user, purpose: "live", started_at: Time.current,
      current_node_uuid: step.uuid, execution_path: [], results: {}, inputs: {}
    )
  end

  # Answers the root question, which opens the sub-flow and leaves the run
  # standing on the child's first question.
  def run_inside_the_subflow
    scenario = scenario_at(@q)
    ScenarioSettler.new(scenario).settle("yes")
    [scenario.reload, scenario.active_child_scenario]
  end

  # A run that finished, still carrying the uuid of the step it finished on —
  # which is what the record actually looks like after a Resolve.
  def finished_run
    scenario = scenario_at(@resolve)
    ScenarioSettler.new(scenario).settle(nil, resolved_here: true)
    scenario.reload
  end

  # --- 1. A finished run shows its ending, not a card asking to be answered ---

  test "Player renders the ending of a finished run, not an answerable card" do
    scenario = finished_run
    assert_predicate scenario, :complete?, "setup: the run has to have finished"

    get player_scenario_step_path(scenario)

    assert_response :success
    assert_select ".runner-thread__complete-item", 1,
                  "a finished run ends the thread; there is nothing left to answer"
    assert_select "#runner-card-current", 0,
                  "an open card on a finished run is a control that can only ever be refused"
  end

  test "Scenario renders the ending of a finished run, not an answerable card" do
    scenario = finished_run

    get step_scenario_path(scenario)

    assert_response :success
    assert_select ".runner-thread__complete-item", 1
    assert_select "#runner-card-current", 0
  end

  # --- 2. The header names the run the agent started ---

  test "Player names the root workflow while the run is inside a sub-flow" do
    _root, child = run_inside_the_subflow

    get player_scenario_step_path(child)

    assert_response :success
    assert_match "Root Workflow", response.body,
                 "the agent started the root run; a sub-flow is not a different call"
  end

  test "Scenario names the root workflow while the run is inside a sub-flow" do
    _root, child = run_inside_the_subflow

    get step_scenario_path(child)

    assert_response :success
    assert_match "Root Workflow", response.body
  end

  # --- 3. A stopped run's results live at the root ---

  test "Scenario sends a stopped sub-flow frame to the root's results" do
    root, child = run_inside_the_subflow
    child.stop!

    get step_scenario_path(child)

    assert_redirected_to scenario_path(root),
                         "stop! stops the whole tree, so the frame has no separate outcome to show"
  end

  test "Player sends a stopped sub-flow frame to the root's results" do
    root, child = run_inside_the_subflow
    child.stop!

    get player_scenario_step_path(child)

    assert_redirected_to player_scenario_show_path(root)
  end

  # --- 4. Answering a run that cannot move writes nothing and says so ---

  test "Player refuses an answer to a stopped run without restamping it" do
    scenario = scenario_at(@q)
    ScenarioSettler.new(scenario).settle("yes")
    scenario.reload.stop!
    before = scenario.reload.execution_path.deep_dup

    post player_scenario_next_path(scenario), params: { answer: "no" },
                                              headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match "already finished", response.body,
                 "dropping the answer in silence is how the agent loses work without knowing"
    assert_equal before, scenario.reload.execution_path,
                 "a refused answer must not restamp the timing of the step before it"
  end

  test "Scenario refuses an answer to a stopped run without restamping it" do
    scenario = scenario_at(@q)
    ScenarioSettler.new(scenario).settle("yes")
    scenario.reload.stop!
    before = scenario.reload.execution_path.deep_dup

    post next_step_scenario_path(scenario), params: { answer: "no" },
                                            headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match "already finished", response.body
    assert_equal before, scenario.reload.execution_path
  end

  # --- 5. A run whose node no longer resolves says so, in both shells ---

  test "Player says there is no step to show rather than falling back to the first one" do
    scenario = scenario_at(@q)
    scenario.update_columns(current_node_uuid: nil)

    get player_scenario_step_path(scenario)

    assert_response :success
    assert_match "There is no step to show", response.body,
                 "silently opening some other step is worse than saying the run is broken"
    assert_no_match(/Root Question/, response.body)
  end
end
