require "test_helper"

# Regression: ISSUE-002 — the builder called every handoff step unconnected
# Found by /qa on 2026-09-12
# Report: .gstack/qa-reports/qa-report-localhost-2026-09-12.md
#
# A Sub-Flow with `sub_flow_returns: false` ends this workflow by handing the run
# on, so it takes no transitions. WorkflowHealthCheck and `condition_summary`
# already knew that. The step row still put a "No connections" warning pill on
# it — 23 of them on one real workflow, beside a health panel reading "All checks
# passing" — and the step panel offered Add Connection directly under a hint
# saying the step takes none.
class HandoffStepBuilderTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    @editor = User.create!(
      email: "handoff-builder-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    @target = Workflow.create!(title: "Handoff Target #{SecureRandom.hex(3)}", user: @editor)
    Steps::Resolve.create!(workflow: @target, position: 0, title: "Done", resolution_type: "success")
    @workflow = Workflow.create!(title: "Handoff Source #{SecureRandom.hex(3)}", user: @editor, graph_mode: true)
    sign_in @editor
  end

  def handoff(title: "Continue elsewhere")
    Steps::SubFlow.create!(workflow: @workflow, position: @workflow.steps.count, title: title,
                           sub_flow_workflow_id: @target.id, sub_flow_returns: false)
  end

  # save(validate: false): GraphValidator refuses a returning sub-flow with
  # nowhere to go, which is exactly the dead end this test needs. That also skips
  # the before_validation that mints the uuid.
  def returning_sub_flow(title: "Into sub-routine")
    step = Steps::SubFlow.new(workflow: @workflow, position: @workflow.steps.count, title: title,
                              uuid: SecureRandom.uuid, sub_flow_workflow_id: @target.id)
    step.save!(validate: false)
    step
  end

  # --- the predicate ---------------------------------------------------------

  test "only a sub-flow that does not come back hands off" do
    assert_predicate handoff, :hands_off?
    assert_not returning_sub_flow.hands_off?
    assert_not Steps::Action.create!(workflow: @workflow, position: 9, title: "Act").hands_off?
  end

  # --- the step row ----------------------------------------------------------

  test "the step row does not flag a handoff as unconnected" do
    step = handoff

    get workflow_path(@workflow)

    assert_response :success
    assert_select "##{dom_id(step)}"
    assert_select "##{dom_id(step)} .badge--warning",
                  count: 0,
                  message: "a handoff ends the workflow on purpose; a warning pill says it was forgotten"
  end

  test "a returning sub-flow with no connections is still flagged" do
    step = returning_sub_flow

    get workflow_path(@workflow)

    assert_select "##{dom_id(step)} .badge--warning", text: "No connections"
  end

  # --- the step panel --------------------------------------------------------

  test "the panel offers no connections to a handoff" do
    step = handoff

    get panel_edit_workflow_step_path(@workflow, step)

    assert_response :success
    assert_select "##{dom_id(step, :connections)}", 1,
                  "the section stays in the page, empty, so toggling Come back can fill it"
    assert_no_match "Add Connection", response.body
    assert_no_match "No connections yet", response.body
  end

  test "a returning sub-flow's panel still offers connections" do
    step = returning_sub_flow

    get panel_edit_workflow_step_path(@workflow, step)

    assert_select "##{dom_id(step, :connections)}", text: /Add Connection/
  end

  # A handoff that somehow carries a transition (an import from before the rule,
  # a hand edit) must still show it, or there is no way to remove it.
  test "a handoff that still carries a connection keeps the editor" do
    step = handoff
    after = Steps::Message.create!(workflow: @workflow, position: 5, title: "After")
    Transition.create!(step: step, target_step: after, position: 0)

    get panel_edit_workflow_step_path(@workflow, step)

    assert_select "##{dom_id(step, :connections)}", text: /Add Connection/
  end

  # --- toggling Come back ----------------------------------------------------
  #
  # The checkbox autosaves, and the save answered with only the step row. So
  # ticking it left the panel without the editor the step now needs, and
  # unticking it left an Add Connection the step can no longer use.

  test "ticking Come back puts the connections editor into the open panel" do
    step = handoff

    patch workflow_step_path(@workflow, step),
          params: { step: { sub_flow_returns: "1" } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_not step.reload.hands_off?
    assert_select "turbo-stream[target=?]", dom_id(step, :connections) do
      assert_select "template", text: /Add Connection/
    end
  end

  test "unticking Come back takes the connections editor out of the open panel" do
    step = returning_sub_flow

    patch workflow_step_path(@workflow, step),
          params: { step: { sub_flow_returns: "0" } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_predicate step.reload, :hands_off?
    assert_select "turbo-stream[target=?]", dom_id(step, :connections)
    assert_no_match "Add Connection", response.body
  end

  test "a save that does not touch Come back leaves the panel's connections alone" do
    step = handoff

    patch workflow_step_path(@workflow, step),
          params: { step: { title: "Renamed" } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_select "turbo-stream[target=?]", dom_id(step, :connections), count: 0
  end
end
