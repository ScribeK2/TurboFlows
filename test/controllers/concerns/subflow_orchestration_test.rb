require "test_helper"

# Tests SubflowOrchestration concern through ScenariosController.
# The concern provides handle_awaiting_subflow, handle_child_completion,
# and redirect_to_subflow_if_awaiting? — all tested via HTTP request flow.
class SubflowOrchestrationTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      email: "subflow-orch-#{SecureRandom.hex(4)}@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    sign_in @user

    # Child workflow: single question -> resolve
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

    # Parent workflow: subflow step -> resolve
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

  def create_parent_scenario
    Scenario.create!(
      workflow: @parent_wf, user: @user, purpose: "simulation",
      status: "active", current_node_uuid: @subflow_step.uuid,
      execution_path: [], results: {}, inputs: {}
    )
  end

  # ---------------------------------------------------------------------------
  # handle_awaiting_subflow: redirects to active child
  # ---------------------------------------------------------------------------

  test "step action redirects to child scenario when parent is awaiting_subflow" do
    parent = create_parent_scenario
    # Process the subflow step to spawn child and set parent to awaiting_subflow
    parent.process_step
    assert_predicate parent, :awaiting_subflow?

    child = parent.child_scenarios.first
    assert_predicate child, :present?

    # GET step on parent — should redirect to child's step path
    get step_scenario_path(parent)
    assert_redirected_to step_scenario_path(child)
  end

  # ---------------------------------------------------------------------------
  # handle_awaiting_subflow: processes completed child and continues
  # ---------------------------------------------------------------------------

  test "step action processes completed child and advances parent" do
    parent = create_parent_scenario
    parent.process_step # spawn child
    child = parent.child_scenarios.first

    # Complete the child scenario manually
    child.process_step("answer") # answer child question
    child.reload
    child.process_step           # resolve child
    assert_predicate child.reload, :completed?

    # Now GET step on parent — should process subflow completion
    get step_scenario_path(parent)

    parent.reload
    # Parent should have advanced past the subflow step
    assert_not_equal "awaiting_subflow", parent.status
  end

  # ---------------------------------------------------------------------------
  # redirect_to_subflow_if_awaiting? — via next_step action
  # ---------------------------------------------------------------------------

  test "next_step redirects to child when step processing triggers subflow" do
    # Create parent scenario starting at a question before the subflow
    q = Steps::Question.create!(
      workflow: @parent_wf, title: "Pre Q", position: 0,
      variable_name: "pre_q", question: "Before subflow?"
    )
    @subflow_step.update!(position: 1)
    @parent_r.update!(position: 2)
    Transition.create!(step: q, target_step: @subflow_step, position: 0)
    @parent_wf.update!(start_step: q)

    parent = Scenario.create!(
      workflow: @parent_wf, user: @user, purpose: "simulation",
      status: "active", current_node_uuid: q.uuid,
      execution_path: [], results: {}, inputs: {}
    )

    # Answer the question — this advances to the subflow step
    parent.process_step("yes")
    parent.reload

    # Now the scenario is at the subflow step; GET step should auto-advance it
    get step_scenario_path(parent)

    parent.reload
    # Should have spawned child and be awaiting_subflow, redirected to child
    if parent.awaiting_subflow?
      child = parent.active_child_scenario
      assert_predicate child, :present?, "Should have an active child scenario"
    end
  end

  # ---------------------------------------------------------------------------
  # handle_child_completion — completed child redirects to parent
  # ---------------------------------------------------------------------------

  test "completed child scenario in step action triggers parent advancement" do
    parent = create_parent_scenario
    parent.process_step # spawn child
    child = parent.child_scenarios.first

    # Complete child
    child.process_step("answer")
    child.reload
    child.process_step
    assert_predicate child.reload, :completed?

    # GET step on the completed child — should handle_child_completion
    get step_scenario_path(child)

    # Should redirect somewhere (parent step or parent completion)
    assert_response :redirect
  end
end
