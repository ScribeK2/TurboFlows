require "test_helper"

# A run that stops because the step it is on has branches and the agent's answer
# matched none of them.
#
# This was recorded as `outcome: "completed"`, which is a member of
# COMPLETED_OUTCOMES, so Analytics counted it as a success. The workflow that
# produces it is not exotic: renaming a Question's variable_name in the step
# panel leaves every condition pointing at the old name, and the health check
# reports zero errors, so a manager can build one in a minute and see nothing
# wrong with it.
class ScenarioStrandedRunTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(
      email: "stranded_#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
  end

  # The bug as a manager reaches it: build a branching question, then rename the
  # variable the branches were written against.
  test "renaming a question's variable strands the run instead of completing it" do
    wf = Workflow.create!(title: "Renamed Variable", user: @user, graph_mode: true, status: "published")
    q  = Steps::Question.create!(workflow: wf, position: 0, title: "Why are they calling?",
                                 question: "Why are they calling?", variable_name: "call_reason",
                                 answer_type: "choice",
                                 options: [{ "label" => "Billing", "value" => "billing" },
                                           { "label" => "Tech", "value" => "tech" }])
    billing = Steps::Resolve.create!(workflow: wf, position: 1, title: "Billing done", resolution_type: "success")
    tech    = Steps::Resolve.create!(workflow: wf, position: 2, title: "Tech done", resolution_type: "success")

    Transition.create!(step: q, target_step: billing, condition: "call_reason == 'billing'", position: 0)
    Transition.create!(step: q, target_step: tech, condition: "call_reason == 'tech'", position: 1)
    wf.update_column(:start_step_id, q.id)

    # The rename. Nothing rewrites the conditions, and nothing refuses the save.
    q.update!(variable_name: "reason_for_call")

    scenario = Scenario.create!(workflow: wf, user: @user, current_node_uuid: q.uuid,
                                inputs: {}, purpose: "live")
    scenario.process_step("billing")
    scenario.reload

    assert_equal "completed", scenario.status, "the frame is finished either way"
    assert_equal "stranded", scenario.outcome
    assert_predicate scenario, :stranded?
    assert_not_includes Scenario::COMPLETED_OUTCOMES, scenario.outcome,
                        "a call nobody could finish must not count toward the completion rate"
  end

  # The trace is the point: the common case is an agent going back and answering
  # differently, which leaves no other sign the workflow has a hole.
  test "the execution path records which step the run fell out of" do
    wf, q = branching_workflow_with_no_matching_answer
    scenario = Scenario.create!(workflow: wf, user: @user, current_node_uuid: q.uuid,
                                inputs: {}, purpose: "live")

    scenario.process_step("maybe")
    scenario.reload

    entry = scenario.execution_path.last
    assert_equal q.uuid, entry["step_uuid"]
    assert entry["no_matching_transition"], "the gap must be on the entry for the step it happened at"
    assert_equal 2, entry["transition_count"], "how many routes were on offer and all missed"
  end

  # The other two ways a run ends with no current node. Neither is a gap, and
  # neither may be relabelled by this change.
  test "reaching a resolve still records resolved" do
    wf = Workflow.create!(title: "Reaches The End", user: @user, graph_mode: true, status: "published")
    q = Steps::Question.create!(workflow: wf, position: 0, title: "Q", question: "Q?",
                                variable_name: "answer", answer_type: "text")
    r = Steps::Resolve.create!(workflow: wf, position: 1, title: "Done", resolution_type: "success")
    Transition.create!(step: q, target_step: r, position: 0)
    wf.update_column(:start_step_id, q.id)

    scenario = Scenario.create!(workflow: wf, user: @user, current_node_uuid: q.uuid,
                                inputs: {}, purpose: "live")
    scenario.process_step("anything")
    scenario.reload
    scenario.process_step
    scenario.reload

    assert_equal "resolved", scenario.outcome
    assert_not_predicate scenario, :stranded?
  end

  test "a step with no outgoing transitions at all still records completed" do
    wf = Workflow.create!(title: "Stops Short", user: @user, graph_mode: true, status: "draft")
    q = Steps::Question.create!(workflow: wf, position: 0, title: "Q", question: "Q?",
                                variable_name: "answer", answer_type: "text")
    Steps::Resolve.create!(workflow: wf, position: 1, title: "Unreached", resolution_type: "success")
    wf.update_column(:start_step_id, q.id)

    scenario = Scenario.create!(workflow: wf, user: @user, current_node_uuid: q.uuid,
                                inputs: {}, purpose: "simulation")
    scenario.process_step("anything")
    scenario.reload

    assert_equal "completed", scenario.outcome,
                 "no edges at all is a half-built draft, not an answer that fell through"
    assert_not_predicate scenario, :stranded?
  end

  # The second place a run can fall through a hole, and the easier one to miss.
  # A sub_flow step's own branches are usually written against a variable the
  # CHILD sets, so a rename inside the child strands the PARENT when the child
  # returns. That path resolves through resolve_next_after_subflow, a different
  # call site from the one an ordinary step uses.
  test "a sub-flow that returns to branches which all miss strands the parent" do
    child = Workflow.create!(title: "Ask The Customer", user: @user, graph_mode: true, status: "published")
    child_q = Steps::Question.create!(workflow: child, position: 0, title: "Did it work?",
                                      question: "Did it work?", answer_type: "yes_no",
                                      variable_name: "fix_worked")
    child_r = Steps::Resolve.create!(workflow: child, position: 1, title: "Asked",
                                     resolution_type: "success")
    Transition.create!(step: child_q, target_step: child_r, position: 0)
    child.update!(start_step: child_q)

    parent = Workflow.create!(title: "Run The Fix", user: @user, graph_mode: true, status: "published")
    sub = Steps::SubFlow.create!(workflow: parent, position: 0, title: "Ask the customer",
                                 sub_flow_workflow_id: child.id, sub_flow_returns: true)
    worked = Steps::Resolve.create!(workflow: parent, position: 1, title: "Done", resolution_type: "success")
    failed = Steps::Resolve.create!(workflow: parent, position: 2, title: "Escalating", resolution_type: "failure")
    # Both branches ask about a variable nothing sets any more: the child now
    # writes `fix_worked`, and these were written before it was renamed.
    Transition.create!(step: sub, target_step: worked, condition: "repair_ok == 'yes'", position: 0)
    Transition.create!(step: sub, target_step: failed, condition: "repair_ok == 'no'", position: 1)
    parent.update!(start_step: sub)

    run = Scenario.create!(workflow: parent, user: @user, current_node_uuid: sub.uuid,
                           inputs: {}, purpose: "live")
    run.process_step
    run.reload

    child_run = run.child_scenarios.sole
    child_run.process_step("yes")
    child_run.reload
    child_run.process_step
    run.reload.process_subflow_completion
    run.reload

    assert_equal "stranded", run.outcome,
                 "the parent came back from the sub-flow with nowhere to go"
    entry = run.execution_path.rfind { |e| e["step_uuid"] == sub.uuid }
    assert entry["no_matching_transition"], "the gap is traced on the sub-flow step's own entry"
    assert_equal 2, entry["transition_count"]
  end

  private

  def branching_workflow_with_no_matching_answer
    wf = Workflow.create!(title: "Two Branches", user: @user, graph_mode: true, status: "published")
    q = Steps::Question.create!(workflow: wf, position: 0, title: "Yes or no?", question: "Yes or no?",
                                variable_name: "answer", answer_type: "choice",
                                options: [{ "label" => "Yes", "value" => "yes" },
                                          { "label" => "No", "value" => "no" }])
    yes = Steps::Resolve.create!(workflow: wf, position: 1, title: "Yes done", resolution_type: "success")
    no  = Steps::Resolve.create!(workflow: wf, position: 2, title: "No done", resolution_type: "success")
    Transition.create!(step: q, target_step: yes, condition: "answer == 'yes'", position: 0)
    Transition.create!(step: q, target_step: no, condition: "answer == 'no'", position: 1)
    wf.update_column(:start_step_id, q.id)
    [wf, q]
  end
end
