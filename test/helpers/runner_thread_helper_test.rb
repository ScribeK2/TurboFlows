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

    kinds = runner_thread_entries(scenario).map { |entry| entry["kind"] }

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

    kinds = flattened_execution_path(scenario).map { |entry| entry["kind"] }

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
end
