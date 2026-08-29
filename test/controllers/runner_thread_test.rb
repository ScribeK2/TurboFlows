require "test_helper"

# What the runner's page looks like, and how it answers a POST.
#
# The run renders as a growing thread: answering collapses the step into a row
# and appends the next card below it, streamed, with no navigation. These assert
# that rendering; the run's *semantics* are covered by the settler's own tests.
class RunnerThreadTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      email: "stacked-#{SecureRandom.hex(4)}@test.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    sign_in @user

    @workflow = Workflow.create!(title: "Stacked WF", user: @user)
    @q1 = Steps::Question.create!(
      workflow: @workflow, title: "Verify the account", position: 0,
      variable_name: "verified", question: "Is the account verified?"
    )
    @q2 = Steps::Question.create!(
      workflow: @workflow, title: "Check the balance", position: 1,
      variable_name: "balance", question: "What is the balance?"
    )
    @resolve = Steps::Resolve.create!(
      workflow: @workflow, title: "Close the call", position: 2, resolution_type: "success"
    )
    Transition.create!(step: @q1, target_step: @q2, position: 0)
    Transition.create!(step: @q2, target_step: @resolve, position: 0)
    @workflow.update!(start_step: @q1)
  end

  def scenario_at(step)
    Scenario.create!(
      workflow: @workflow, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: step.uuid, execution_path: [], results: {}, inputs: {}
    )
  end

  test "answered steps stay on the page as rows, above the open card" do
    scenario = scenario_at(@q1)
    ScenarioSettler.new(scenario).settle("Yes")

    get step_scenario_path(scenario)

    assert_response :success
    assert_select "ol#runner-thread"
    assert_select ".runner-thread__row", 1, "the answered step is still on screen"
    assert_select ".runner-thread__row .runner-thread__summary", text: "Yes"
    assert_select "#runner-card-current", 1, "and exactly one step is open"
  end

  test "the open card is the step the run is actually on" do
    scenario = scenario_at(@q1)
    ScenarioSettler.new(scenario).settle("Yes")

    get step_scenario_path(scenario)

    assert_select "#runner-card-current h2", text: "Check the balance"
  end

  test "a finished run keeps its transcript instead of being replaced" do
    scenario = scenario_at(@q1)
    ScenarioSettler.new(scenario).settle("Yes")
    ScenarioSettler.new(scenario).settle("100")
    ScenarioSettler.new(scenario).settle(nil)
    assert_predicate scenario.reload, :complete?, "precondition"

    get step_scenario_path(scenario)

    assert_response :success, "a finished run keeps its ending on the thread instead of navigating away"
    assert_select ".runner-thread__row", minimum: 2
    assert_select "#runner-card-current", 0, "nothing is open once the run is done"
    assert_select ".runner-thread__complete a", text: "View results"
  end

  test "the thread marks where the call moved into a sub-flow" do
    child_wf = Workflow.create!(title: "Billing Check", user: @user)
    cq = Steps::Question.create!(workflow: child_wf, title: "CQ", position: 0, variable_name: "cv")
    cr = Steps::Resolve.create!(workflow: child_wf, title: "CDone", position: 1)
    Transition.create!(step: cq, target_step: cr, position: 0)
    child_wf.update!(start_step: cq)

    wf = Workflow.create!(title: "With Subflow", user: @user)
    q = Steps::Question.create!(workflow: wf, title: "Opening", position: 0, variable_name: "ov")
    sf = Steps::SubFlow.create!(workflow: wf, title: "SF", position: 1, sub_flow_workflow_id: child_wf.id)
    after = Steps::Question.create!(workflow: wf, title: "Wrap up", position: 2, variable_name: "av")
    done = Steps::Resolve.create!(workflow: wf, title: "Done", position: 3)
    Transition.create!(step: q, target_step: sf, position: 0)
    Transition.create!(step: sf, target_step: after, position: 0)
    Transition.create!(step: after, target_step: done, position: 0)
    wf.update!(start_step: q)

    scenario = Scenario.create!(
      workflow: wf, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: q.uuid, execution_path: [], results: {}, inputs: {}
    )
    child = ScenarioSettler.new(scenario).settle("Yes").scenario
    ScenarioSettler.new(child).settle("ChildAnswer")

    get step_scenario_path(scenario.reload)

    assert_select ".runner-thread__group", 1
    assert_select ".runner-thread__group", text: /Billing Check/
    assert_select ".runner-thread__row", text: /CQ/,
                                         count: 1
  end

  test "steps inside a sub-flow are indented and the run outdents on the way out" do
    child_wf = Workflow.create!(title: "Inner", user: @user)
    cq = Steps::Question.create!(workflow: child_wf, title: "CQ", position: 0, variable_name: "cv")
    cr = Steps::Resolve.create!(workflow: child_wf, title: "CDone", position: 1)
    Transition.create!(step: cq, target_step: cr, position: 0)
    child_wf.update!(start_step: cq)

    wf = Workflow.create!(title: "Outer", user: @user)
    q = Steps::Question.create!(workflow: wf, title: "Opening", position: 0, variable_name: "ov")
    sf = Steps::SubFlow.create!(workflow: wf, title: "SF", position: 1, sub_flow_workflow_id: child_wf.id)
    after = Steps::Question.create!(workflow: wf, title: "Wrap up", position: 2, variable_name: "av")
    done = Steps::Resolve.create!(workflow: wf, title: "Done", position: 3)
    Transition.create!(step: q, target_step: sf, position: 0)
    Transition.create!(step: sf, target_step: after, position: 0)
    Transition.create!(step: after, target_step: done, position: 0)
    wf.update!(start_step: q)

    scenario = Scenario.create!(
      workflow: wf, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: q.uuid, execution_path: [], results: {}, inputs: {}
    )
    child = ScenarioSettler.new(scenario).settle("Yes").scenario
    ScenarioSettler.new(child).settle("ChildAnswer")

    get step_scenario_path(scenario.reload)

    assert_select ".runner-thread__row[style*='--thread-depth: 0']", text: /Opening/
    assert_select ".runner-thread__row[style*='--thread-depth: 1']", text: /CQ/,
                                                                     count: 1
  end
  # Indentation is the sub-flow's closing bracket: coming back out is what tells
  # a reader it ended. So the open card has to sit at the depth of the scenario
  # it belongs to — an outdented card while the run is still inside one says the
  # sub-flow finished when it has not.
  test "the open card stays indented while the run is inside a sub-flow" do
    child_wf = Workflow.create!(title: "Billing", user: @user)
    c1 = Steps::Question.create!(workflow: child_wf, title: "Card current?", position: 0, variable_name: "c1")
    c2 = Steps::Question.create!(workflow: child_wf, title: "Failed payments?", position: 1, variable_name: "c2")
    cr = Steps::Resolve.create!(workflow: child_wf, title: "Billing done", position: 2)
    Transition.create!(step: c1, target_step: c2, position: 0)
    Transition.create!(step: c2, target_step: cr, position: 0)
    child_wf.update!(start_step: c1)

    wf = Workflow.create!(title: "Recovery", user: @user)
    q = Steps::Question.create!(workflow: wf, title: "Verify", position: 0, variable_name: "v")
    sf = Steps::SubFlow.create!(workflow: wf, title: "Billing", position: 1, sub_flow_workflow_id: child_wf.id)
    after = Steps::Question.create!(workflow: wf, title: "Wrap", position: 2, variable_name: "w")
    done = Steps::Resolve.create!(workflow: wf, title: "Close", position: 3)
    Transition.create!(step: q, target_step: sf, position: 0)
    Transition.create!(step: sf, target_step: after, position: 0)
    Transition.create!(step: after, target_step: done, position: 0)
    wf.update!(start_step: q)

    scenario = Scenario.create!(
      workflow: wf, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: q.uuid, execution_path: [], results: {}, inputs: {}
    )
    inside = ScenarioSettler.new(scenario).settle("Yes").scenario
    ScenarioSettler.new(inside).settle("Yes")

    get step_scenario_path(inside.reload)

    assert_select "#runner-card-current[style*='--thread-depth: 1']", 1,
                  "the run is still inside the sub-flow, so the card must not outdent"
  end
  # Both shells ship together — diverging them is what the shared step body and
  # the shared advance seam exist to prevent — so the Player gets the same
  # assertions, not a promise that it works because the Scenario runner does.
  test "the Player renders the thread too" do
    @workflow.update!(status: "published")
    scenario = Scenario.create!(
      workflow: @workflow, user: @user, purpose: "live", started_at: Time.current,
      current_node_uuid: @q1.uuid, execution_path: [], results: {}, inputs: {}
    )
    ScenarioSettler.new(scenario).settle("Yes")

    get player_scenario_step_path(scenario)

    assert_response :success
    assert_select "ol#runner-thread"
    assert_select ".runner-thread__row", 1
    assert_select ".runner-thread__row .runner-thread__summary", text: "Yes"
    assert_select "#runner-card-current", 1
    assert_select ".runner-trail", 0
  end

  test "an anonymous shared run gets the thread" do
    @workflow.update!(status: "published", share_token: SecureRandom.hex(8))
    sign_out @user

    get shared_player_path(@workflow.share_token)
    follow_redirect!

    assert_response :success
    assert_select "ol#runner-thread", 1,
                  "share links are the surface least able to report what they saw — " \
                  "they must not get a different runner from the author"
  end
  # A stopped run leaves the thread in both shells. "Stopped" is abandonment,
  # not an ending worth reading back — and _thread_complete says "this run is
  # complete", which a stopped run is not. Pinned in both shells because
  # Scenario#complete? returns true for stopped runs, so the only thing keeping
  # a stopped run off the thread is guard order.
  test "a stopped run leaves the thread rather than claiming to be complete" do
    scenario = scenario_at(@q1)
    ScenarioSettler.new(scenario).settle("Yes")
    scenario.stop!

    get step_scenario_path(scenario)

    assert_redirected_to scenario_path(scenario)
  end

  test "the Player also leaves a stopped run" do
    @workflow.update!(status: "published")
    scenario = Scenario.create!(
      workflow: @workflow, user: @user, purpose: "live", started_at: Time.current,
      current_node_uuid: @q1.uuid, execution_path: [], results: {}, inputs: {}
    )
    ScenarioSettler.new(scenario).settle("Yes")
    scenario.stop!

    get player_scenario_step_path(scenario)

    assert_redirected_to player_scenario_show_path(scenario)
  end
  # --- streaming the answer -------------------------------------------------

  test "answering streams the thread forward instead of redirecting" do
    scenario = scenario_at(@q1)

    post next_step_scenario_path(scenario), params: { answer: "Yes" },
                                            headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_match(/turbo-stream/, response.body)
  end

  test "the answered step becomes a row and the next step becomes the open card" do
    scenario = scenario_at(@q1)

    post next_step_scenario_path(scenario), params: { answer: "Yes" },
                                            headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_match(/runner-thread__row/, response.body, "the step just answered collapses into a row")
    assert_match(/Verify the account/, response.body)
    assert_match(/runner-card-current/, response.body, "and the next one opens")
    assert_match(/Check the balance/, response.body)
  end

  test "a refused step re-renders the card without appending anything" do
    wf = Workflow.create!(title: "Blocking WF", user: @user)
    esc = Steps::Escalate.create!(
      workflow: wf, title: "Escalate", position: 0,
      target_type: "supervisor", reason_required: true
    )
    done = Steps::Resolve.create!(workflow: wf, title: "Done", position: 1)
    Transition.create!(step: esc, target_step: done, position: 0)
    wf.update!(start_step: esc)
    scenario = Scenario.create!(
      workflow: wf, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: esc.uuid, execution_path: [], results: {}, inputs: {}
    )

    post next_step_scenario_path(scenario),
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :unprocessable_entity, "a refusal is not a new step"
    assert_match(/Escalation reason is required/, response.body)
    assert_match(/runner-card-current/, response.body)
    assert_no_match(/runner-thread__row/, response.body, "nothing was answered, so nothing collapses")
  end
  test "going back streams the thread without a redirect" do
    scenario = scenario_at(@q1)
    ScenarioSettler.new(scenario).settle("Yes")

    post back_scenario_path(scenario),
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
  end

  test "going back reopens the step it undid and drops its row" do
    scenario = scenario_at(@q1)
    ScenarioSettler.new(scenario).settle("Yes")

    post back_scenario_path(scenario),
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_match(/runner-card-current/, response.body)
    assert_match(/Verify the account/, response.body, "the step just undone is open again")
    assert_no_match(/runner-thread__summary/, response.body,
                    "and its row is gone, because the thread shrank")
  end

  # --- inputs the two shells must read identically ---------------------------

  test "the Player's Resolved button actually resolves the run" do
    wf = Workflow.create!(title: "Resolvable WF", user: @user, status: "published")
    act = Steps::Action.create!(workflow: wf, title: "Try the reset", position: 0, can_resolve: true)
    nxt = Steps::Question.create!(workflow: wf, title: "Still broken?", position: 1, variable_name: "b")
    done = Steps::Resolve.create!(workflow: wf, title: "Done", position: 2)
    Transition.create!(step: act, target_step: nxt, position: 0)
    Transition.create!(step: nxt, target_step: done, position: 0)
    wf.update!(start_step: act)

    scenario = Scenario.create!(
      workflow: wf, user: @user, purpose: "live", started_at: Time.current,
      current_node_uuid: act.uuid, execution_path: [], results: {}, inputs: {}
    )

    # The shared button bar submits resolved_here — the same name the Scenario
    # runner reads.
    post player_scenario_next_path(scenario), params: { resolved_here: "true" }

    assert_predicate scenario.reload, :complete?,
                     "the Player read a different param name than the shared form submits, " \
                     "so its Resolved button quietly advanced instead of resolving"
  end

  test "the Scenario runner's Resolved button resolves too" do
    wf = Workflow.create!(title: "Resolvable WF 2", user: @user)
    act = Steps::Action.create!(workflow: wf, title: "Try the reset", position: 0, can_resolve: true)
    nxt = Steps::Question.create!(workflow: wf, title: "Still broken?", position: 1, variable_name: "b")
    done = Steps::Resolve.create!(workflow: wf, title: "Done", position: 2)
    Transition.create!(step: act, target_step: nxt, position: 0)
    Transition.create!(step: nxt, target_step: done, position: 0)
    wf.update!(start_step: act)

    scenario = Scenario.create!(
      workflow: wf, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: act.uuid, execution_path: [], results: {}, inputs: {}
    )

    post next_step_scenario_path(scenario), params: { resolved_here: "true" }

    assert_predicate scenario.reload, :complete?
  end

  # A run that could not move, as opposed to one that was refused. Classic says
  # so; the streamed path must too, or the agent's answer disappears in silence —
  # the exact bug fixed one PR ago on the other path.
  test "answering a run that has already finished says so" do
    scenario = scenario_at(@q1)
    ScenarioSettler.new(scenario).settle("Yes")
    ScenarioSettler.new(scenario).settle("100")
    ScenarioSettler.new(scenario).settle(nil)
    assert_predicate scenario.reload, :complete?, "precondition"

    post next_step_scenario_path(scenario), params: { answer: "late" },
                                            headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match(/already finished/i, response.body,
                 "a stale tab must not have its answer swallowed")
    assert_no_match(/runner-thread__row/, response.body, "and nothing new collapses")
  end

  test "a halted answer leaves exactly one open card" do
    scenario = scenario_at(@q1)
    ScenarioSettler.new(scenario).settle("Yes")
    ScenarioSettler.new(scenario).settle("100")
    ScenarioSettler.new(scenario).settle(nil)

    post next_step_scenario_path(scenario), params: { answer: "late" },
                                            headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_equal 1, response.body.scan('runner-card-current').length,
                 "the stream must not leave two open cards on the page"
  end

  # The thread's tail has to say *something* for a run that is not parked, not
  # complete, and has no step to open. Both classic shells carried their own
  # wording for this; when they went, the tail rendered an empty <ol> instead.
  #
  # Reachable, not theoretical: step uuids are immutable but steps get deleted,
  # and nothing in #step guards a current_node_uuid that no longer resolves.
  test "a run whose current step no longer resolves says so" do
    scenario = scenario_at(@q1)
    scenario.update!(current_node_uuid: SecureRandom.uuid)

    get step_scenario_path(scenario)

    assert_response :success
    assert_select "#runner-card-current", 1,
                  "the tail must still render an anchor a streamed answer could replace"
    assert_match(/no step to show/i, response.body,
                 "an unresolvable run explains itself rather than rendering an empty list")
  end
end
