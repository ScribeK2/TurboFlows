require "test_helper"

# The traversal behind both the runner thread and the results page.
#
# One walk, two readers. The results page wants a flat audit list; the thread
# wants the sub-flow structure. Sharing the traversal — which is recursive,
# subtle and already carries a performance fix — while differing only at the
# call site is what keeps them from drifting.
class RunnerThreadHelperTest < ActionView::TestCase
  include ScenariosHelper
  include RunnerHelper

  setup do
    @user = User.create!(email: "thread-helper-#{SecureRandom.hex(4)}@example.com", password: "password123456")

    @child_wf = Workflow.create!(title: "Billing Check", user: @user)
    cq = Steps::Question.create!(workflow: @child_wf, title: "CQ", position: 0, variable_name: "cv")
    cr = Steps::Resolve.create!(workflow: @child_wf, title: "CDone", position: 1)
    Transition.create!(step: cq, target_step: cr, position: 0)
    @child_wf.update!(start_step: cq)

    @workflow = Workflow.create!(title: "Parent", user: @user)
    @q1 = Steps::Question.create!(workflow: @workflow, title: "Q1", position: 0, variable_name: "q1v")
    @sf = Steps::SubFlow.create!(workflow: @workflow, title: "SF", position: 1, sub_flow_workflow_id: @child_wf.id)
    @after = Steps::Question.create!(workflow: @workflow, title: "After", position: 2, variable_name: "av")
    done = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 3)
    Transition.create!(step: @q1, target_step: @sf, position: 0)
    Transition.create!(step: @sf, target_step: @after, position: 0)
    Transition.create!(step: @after, target_step: done, position: 0)
    @workflow.update!(start_step: @q1)
  end

  # Q1 -> [sub-flow: CQ] -> After
  def run_through_subflow
    scenario = Scenario.create!(
      workflow: @workflow, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: @q1.uuid, execution_path: [], results: {}, inputs: {}
    )
    child = ScenarioSettler.new(scenario).settle("Yes").scenario
    ScenarioSettler.new(child).settle("ChildAnswer")
    scenario.reload
  end

  test "the thread marks where a sub-flow began" do
    scenario = run_through_subflow

    kinds = runner_thread_entries(scenario).pluck("kind")

    assert_includes kinds, "group_start",
                    "entering a sub-flow is a fact about the call, not just about the engine"
  end

  test "the group carries the workflow the call moved into" do
    scenario = run_through_subflow

    group = runner_thread_entries(scenario).find { |entry| entry["kind"] == "group_start" }

    assert_equal "Billing Check", group["target_workflow_title"]
  end

  test "steps inside a sub-flow sit one level deeper" do
    scenario = run_through_subflow

    entries = runner_thread_entries(scenario)
    outer = entries.find { |e| e["step_title"] == "Q1" }
    inner = entries.find { |e| e["step_title"] == "CQ" }

    assert_equal 0, outer["depth"]
    assert_equal 1, inner["depth"], "the outdent is what tells a reader the sub-flow ended"
  end

  test "the results page sees a flat list with no grouping marks" do
    scenario = run_through_subflow

    kinds = flattened_execution_path(scenario).pluck("kind")

    assert_not_includes kinds, "group_start",
                        "an audit list wants the steps, not the structure"
    assert_includes flattened_execution_path(scenario).pluck("step_title"), "CQ",
                    "but it still wants the steps that happened inside"
  end
  # What a completed row says, per step type. The row reads the entry and only
  # the entry: steps get edited and deleted after runs, so reading the live
  # record would replay a call with text nobody saw, or fail on a missing uuid.
  test "a question row shows the answer" do
    assert_equal "Yes", runner_row_summary("step_type" => "question", "answer" => "Yes")
  end

  test "a form row shows what was submitted" do
    summary = runner_row_summary("step_type" => "form", "response_summary" => "name: Ada, plan: Pro")

    assert_equal "name: Ada, plan: Pro", summary
  end

  test "an escalate row shows where the call went" do
    summary = runner_row_summary("step_type" => "escalate", "target_type" => "supervisor", "priority" => "urgent")

    assert_equal "Escalated to supervisor — urgent", summary
  end

  test "an escalate row without a recorded target still says it escalated" do
    assert_equal "Escalated", runner_row_summary("step_type" => "escalate")
  end

  test "a resolve row shows how the run ended" do
    assert_equal "Resolved — transfer", runner_row_summary("step_type" => "resolve", "resolution_type" => "transfer")
  end

  test "action and message rows say they were done, not what they said" do
    assert_equal "Done", runner_row_summary("step_type" => "action")
    assert_equal "Read", runner_row_summary("step_type" => "message")
  end

  test "a row with nothing to report says nothing rather than guessing" do
    assert_nil runner_row_summary("step_type" => "question")
  end

  # Which terminal a sub-flow leaves behind.
  #
  # A child's last entry is dropped, because the child's own ending is the
  # sub-flow ending and not the run ending — the next card already implies it.
  # That rule was written when a child's terminal was always auto-processed and
  # never shown. It can now be a step the agent actually filled in, and dropping
  # a step somebody answered is a different rule that used to coincide with this
  # one.
  #
  # The line drawn: a terminal that carries the person's own words stays.

  test "a child's auto-processed Resolve is still dropped" do
    scenario = run_through_subflow

    titles = runner_thread_entries(scenario).pluck("step_title")

    assert_includes titles, "CQ", "the step the agent answered is on the transcript"
    assert_not_includes titles, "CDone",
                        "nobody saw this step; the sub-flow ending is the next card"
  end

  test "a child's Resolve stays when the agent typed the notes it asked for" do
    notes_wf = Workflow.create!(title: "Notes Child", user: @user)
    resolve = Steps::Resolve.create!(workflow: notes_wf, title: "Confirm identity", position: 0,
                                     resolution_type: "success", notes_required: true)
    notes_wf.update!(start_step: resolve)
    @sf.update!(sub_flow_workflow_id: notes_wf.id)

    scenario = Scenario.create!(
      workflow: @workflow, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: @q1.uuid, execution_path: [], results: {}, inputs: {}
    )
    child = ScenarioSettler.new(scenario).settle("Yes").scenario
    child.inputs["resolution_notes"] = "Checked DOB and last four"
    ScenarioSettler.new(child).settle(nil, resolved_here: true)

    titles = runner_thread_entries(scenario.reload).pluck("step_title")

    assert_includes titles, "Confirm identity",
                    "the agent stopped and typed here; the transcript has to show it happened"
  end

  # An escalate can only be a child's *terminal* in a graph that predates or
  # bypasses validation — GraphValidator requires every terminal node to be a
  # Resolve, so a valid child ends on one. The branch is defensive, and it is
  # tested at the entry rather than through a run that cannot be built.
  test "a child's Escalate terminal stays when the entry carries the typed reason" do
    child = Scenario.create!(
      workflow: @child_wf, user: @user, inputs: {},
      execution_path: [
        { "step_title" => "CQ", "answer" => "yes", "step_type" => "question" },
        { "step_title" => "Hand to supervisor", "step_type" => "escalate",
          "escalated" => true, "target_type" => "supervisor",
          "reason" => "Customer asked for a manager" }
      ]
    )
    parent = Scenario.create!(
      workflow: @workflow, user: @user, inputs: {}, status: "awaiting_subflow",
      execution_path: [
        { "subflow_started" => true, "child_scenario_id" => child.id, "step_type" => "sub_flow" }
      ]
    )
    child.update!(parent_scenario: parent)

    titles = runner_thread_entries(parent).pluck("step_title")

    assert_includes titles, "Hand to supervisor",
                    "an escalate the agent explained is the most important row on the call"
  end

  test "a terminal recorded before the words were kept degrades to being dropped" do
    child = Scenario.create!(
      workflow: @child_wf, user: @user, inputs: {},
      execution_path: [
        { "step_title" => "CQ", "answer" => "yes", "step_type" => "question" },
        { "step_title" => "CDone", "step_type" => "resolve", "resolved" => true }
      ]
    )
    parent = Scenario.create!(
      workflow: @workflow, user: @user, inputs: {}, status: "awaiting_subflow",
      execution_path: [
        { "subflow_started" => true, "child_scenario_id" => child.id, "step_type" => "sub_flow" }
      ]
    )
    child.update!(parent_scenario: parent)

    titles = runner_thread_entries(parent).pluck("step_title")

    assert_not_includes titles, "CDone",
                        "an entry from before the words were recorded cannot prove anyone answered it"
  end

  # These three came from the trail's tests when the trail was deleted. They are
  # properties of the traversal, not of the surface that used to render it: the
  # thread reads from the root exactly as the trail did, and the query guard and
  # the empty case matter more now that this is the only reader on the page.

  test "the thread spans the whole run, not the sub-flow frame it is read from" do
    child = Scenario.create!(
      workflow: @workflow, user: @user, inputs: {},
      execution_path: [{ "step_title" => "Verify identity", "answer" => "yes", "step_type" => "question" }]
    )
    parent = Scenario.create!(
      workflow: @workflow, user: @user, inputs: {}, status: "awaiting_subflow",
      execution_path: [
        { "step_title" => "Confirm Issue", "answer" => "yes", "step_type" => "question" },
        { "subflow_started" => true, "child_scenario_id" => child.id, "step_type" => "sub_flow" }
      ]
    )
    child.update!(parent_scenario: parent)

    # Read from the child, as the runner does while inside a sub-flow. The old
    # stepper showed only the child's own path numbered from 1, beside a counter
    # that counted across ancestors — "Step 1" sitting next to "Step 4".
    titles = runner_thread_entries(child).select { |e| e["kind"] == "step" }.pluck("step_title")

    assert_equal ["Confirm Issue", "Verify identity"], titles,
                 "the thread must span the whole run, oldest first"
  end

  test "the thread costs one query per nesting level, not one per sub-flow" do
    children = Array.new(3) do
      Scenario.create!(workflow: @workflow, user: @user, inputs: {},
                       execution_path: [{ "step_title" => "child", "answer" => "yes", "step_type" => "question" }])
    end
    root = Scenario.create!(
      workflow: @workflow, user: @user, inputs: {}, status: "awaiting_subflow",
      execution_path: children.map { |c| { "subflow_started" => true, "child_scenario_id" => c.id, "step_type" => "sub_flow" } }
    )
    children.each { |c| c.update!(parent_scenario: root) }

    # The thread re-renders on every step, so a query per sub-flow entry would
    # scale with the run's branching.
    assert_queries_count(1) { runner_thread_entries(root) }
  end

  test "the thread is empty for a run that has not answered anything yet" do
    scenario = Scenario.create!(workflow: @workflow, user: @user, inputs: {}, execution_path: [])

    assert_empty runner_thread_entries(scenario)
  end
end
