require "test_helper"

# The runner with the thread turned on.
#
# The flag covers rendering and response style only — everything else in this
# project landed unconditionally — so these assert what the page looks like, and
# the rest of the suite running with the flag off is the classic baseline.
class StackedRunnerTest < ActionDispatch::IntegrationTest
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

  def with_stacked_runner
    original = Rails.configuration.x.stacked_runner
    Rails.configuration.x.stacked_runner = true
    yield
  ensure
    Rails.configuration.x.stacked_runner = original
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

    with_stacked_runner { get step_scenario_path(scenario) }

    assert_response :success
    assert_select "ol#runner-thread"
    assert_select ".runner-thread__row", 1, "the answered step is still on screen"
    assert_select ".runner-thread__row .runner-thread__summary", text: "Yes"
    assert_select "#runner-card-current", 1, "and exactly one step is open"
  end

  test "the open card is the step the run is actually on" do
    scenario = scenario_at(@q1)
    ScenarioSettler.new(scenario).settle("Yes")

    with_stacked_runner { get step_scenario_path(scenario) }

    assert_select "#runner-card-current h2", text: "Check the balance"
  end

  test "the trail is not rendered alongside the thread" do
    scenario = scenario_at(@q1)
    ScenarioSettler.new(scenario).settle("Yes")

    with_stacked_runner { get step_scenario_path(scenario) }

    assert_select ".runner-trail", 0,
                  "two lists of the same answers is the bug the trail was written to fix"
  end

  test "classic still renders one card and the trail" do
    scenario = scenario_at(@q1)
    ScenarioSettler.new(scenario).settle("Yes")

    get step_scenario_path(scenario)

    assert_select "ol#runner-thread", 0
    assert_select ".runner-trail", 1
  end

  test "a finished run keeps its transcript instead of being replaced" do
    scenario = scenario_at(@q1)
    ScenarioSettler.new(scenario).settle("Yes")
    ScenarioSettler.new(scenario).settle("100")
    ScenarioSettler.new(scenario).settle(nil)
    assert_predicate scenario.reload, :complete?, "precondition"

    with_stacked_runner { get step_scenario_path(scenario) }

    assert_response :success, "classic redirects to results here; stacked keeps the ending on the thread"
    assert_select ".runner-thread__row", minimum: 2
    assert_select "#runner-card-current", 0, "nothing is open once the run is done"
    assert_select ".runner-thread__complete a", text: "View results"
  end

  test "classic still replaces a finished run with the completion card" do
    scenario = scenario_at(@q1)
    ScenarioSettler.new(scenario).settle("Yes")
    ScenarioSettler.new(scenario).settle("100")
    ScenarioSettler.new(scenario).settle(nil)

    get step_scenario_path(scenario)

    assert_redirected_to scenario_path(scenario)
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

    with_stacked_runner { get step_scenario_path(scenario.reload) }

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

    with_stacked_runner { get step_scenario_path(scenario.reload) }

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

    with_stacked_runner { get step_scenario_path(inside.reload) }

    assert_select "#runner-card-current[style*='--thread-depth: 1']", 1,
                  "the run is still inside the sub-flow, so the card must not outdent"
  end
end
