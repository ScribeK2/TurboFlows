require "test_helper"

# What a handoff does to the half it leaves behind, and to everything waiting on it.
#
# The spike established the rule — a handoff is not "this frame ends" but "every
# frame waiting on this one ends" — by finding the failure it prevents:
# `A -> sub-flow B -> handoff C` left A `awaiting_subflow` and `parked?`, offering
# a Resume that calls `process_subflow_completion`, which picks the newest
# *completed* child and resurrects A. Twice found at `scenario.rb:314` by review,
# once more by the spike.
#
# The split matters:
# `status` carries terminality, `outcome` carries how the run ended. A handed-off
# run is not a completed one, and reporting has to be able to tell them apart.
class ScenarioHandoffTerminationTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "term-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    @wf = Workflow.create!(title: "W #{SecureRandom.hex(3)}", user: @user)
  end

  def scenario(parent: nil, status: "active", node: "node-#{SecureRandom.hex(3)}")
    Scenario.create!(workflow: @wf, user: @user, purpose: "simulation", status: status,
                     started_at: 5.minutes.ago, parent_scenario: parent,
                     current_node_uuid: node, execution_path: [], results: {}, inputs: {})
  end

  # --- the outcome value has to exist before any of this works ---------------

  test "transferred is a real outcome" do
    assert_includes Scenario::OUTCOMES, "transferred",
                    "the inclusion validation refuses anything else, so this gates the whole feature"
  end

  # --- the frame the run left --------------------------------------------------

  test "handing off settles this frame as completed-but-transferred" do
    source = scenario

    source.hand_off!

    source.reload
    assert_equal "completed", source.status,
                 "the only TERMINAL_STATUSES member that reads correctly: terminal? true, parked? false"
    assert_equal "transferred", source.outcome,
                 "status says the frame is finished; outcome says how, and it did not complete"
    assert_nil source.current_node_uuid, "the run is not sitting on a node here any more"
    assert_not_nil source.completed_at
    assert_predicate source, :terminal?
    assert_not_predicate source, :parked?
  end

  test "a transferred frame records its duration like any other ending" do
    source = scenario

    source.hand_off!

    assert_operator source.reload.duration_seconds, :>=, 0,
                    "a handed-off half is still a run that took time; reporting reads this"
  end

  # --- everything that was waiting on it ---------------------------------------

  test "an ancestor waiting on the handed-off frame is settled too" do
    a = scenario(status: "awaiting_subflow")
    b = scenario(parent: a)

    b.hand_off!

    a.reload
    assert_equal "completed", a.status, "A is waiting for a return that will never come"
    assert_equal "transferred", a.outcome
    assert_not_predicate a, :parked?,
                         "this is the resurrection bug: a parked A offers a Resume that revives it"
  end

  test "the whole waiting chain is settled, not just the immediate parent" do
    a = scenario(status: "awaiting_subflow")
    b = scenario(parent: a, status: "awaiting_subflow")
    c = scenario(parent: b)

    c.hand_off!

    assert_equal %w[completed completed], [a.reload.status, b.reload.status]
    assert_equal(%w[transferred transferred], [a.outcome, b.outcome])
  end

  # The guard against over-reaching: only frames actually *waiting* on this run
  # are settled. An ancestor that already ended keeps the ending it earned.
  test "an ancestor that already finished keeps its own outcome" do
    a = scenario(status: "completed")
    a.update!(outcome: "resolved")
    b = scenario(parent: a)

    b.hand_off!

    assert_equal "resolved", a.reload.outcome,
                 "settling a run must never overwrite an ending that already happened"
  end

  test "a stopped ancestor is left stopped" do
    a = scenario(status: "stopped")
    a.update!(outcome: "abandoned")
    b = scenario(parent: a)

    b.hand_off!

    assert_equal "stopped", a.reload.status
    assert_equal "abandoned", a.outcome
  end

  # --- it must go through the model, not around it -----------------------------

  test "handing off bumps lock_version, so it is a real save and not update_columns" do
    source = scenario
    before = source.lock_version

    source.hand_off!

    assert_operator source.reload.lock_version, :>, before,
                    "the spike used update_columns, which skips validations, callbacks and locking"
  end

  test "a sibling branch that is not an ancestor is untouched" do
    a = scenario(status: "awaiting_subflow")
    b = scenario(parent: a)
    other = scenario

    b.hand_off!

    assert_equal "active", other.reload.status, "only the chain waiting on this run ends"
  end

  # --- how a handoff step reads in the builder --------------------------------
  #
  # `condition_summary` prints "Terminal" only for a Resolve, and a handoff has
  # no transitions, so the step row and the flow diagram rendered it as a step
  # that simply goes nowhere — indistinguishable from the dead end the health
  # panel warns about.

  test "a handoff step reads as terminal, naming where it hands off to" do
    target = Workflow.create!(title: "Escalation Path", user: @user)
    Steps::Resolve.create!(workflow: target, position: 0, title: "Done", resolution_type: "success")
    target.update!(start_step: target.steps.first)

    source = Workflow.create!(title: "Src #{SecureRandom.hex(3)}", user: @user)
    handoff = Steps::SubFlow.create!(workflow: source, position: 0, title: "Continue",
                                     sub_flow_workflow_id: target.id, sub_flow_returns: false)

    assert_predicate handoff, :terminal?
    assert_equal "Continues in Escalation Path", handoff.condition_summary,
                 "a handoff ends this workflow on purpose; saying nothing reads as a dead end"
  end

  test "a returning sub_flow with no transitions still reads as unfinished" do
    target = Workflow.create!(title: "Sub Routine", user: @user)
    Steps::Resolve.create!(workflow: target, position: 0, title: "Done", resolution_type: "success")
    target.update!(start_step: target.steps.first)

    source = Workflow.create!(title: "Src #{SecureRandom.hex(3)}", user: @user)
    # save(validate: false) because GraphValidator refuses this shape, which is
    # the point of the test. That also skips the before_validation that mints the
    # uuid, so it is supplied here.
    sub = Steps::SubFlow.new(workflow: source, position: 0, title: "Into Sub",
                             uuid: SecureRandom.uuid, sub_flow_workflow_id: target.id)
    sub.save!(validate: false)

    assert_nil sub.condition_summary,
               "it will come back and has nowhere to come back to — that is a real dead end"
  end

  # --- the link has to survive retention, or admit that it did not ------------
  #
  # `CleanupScenariosJob` deletes with `delete_all`, and says why in its own
  # comment: it bypasses callbacks, so `dependent:` cannot be relied on and the
  # parent link is protected by a database FK with ON DELETE SET NULL instead.
  # `handed_off_from_id` shipped with an index and no FK, so reaping a source
  # left the column pointing at an id that no longer existed — and `run_origin`
  # then resolved to the head itself, dropping the run's whole transcript.

  test "reaping a handed-off source nullifies the link rather than dangling" do
    source = scenario
    head = Scenario.create!(workflow: @wf, user: @user, purpose: "simulation", status: "active",
                            started_at: Time.current, handed_off_from: source,
                            execution_path: [], results: {}, inputs: {})

    # Exactly what the cleanup job does — no callbacks.
    Scenario.where(id: source.id).delete_all

    assert_nil head.reload.handed_off_from_id,
               "a column pointing at a deleted row is an invariant this schema holds everywhere else"
  end

  test "the handoff link is protected the same way the parent link is" do
    keys = ActiveRecord::Base.connection.foreign_keys("scenarios")
    handoff = keys.find { |k| k.options[:column] == "handed_off_from_id" }
    parent = keys.find { |k| k.options[:column] == "parent_scenario_id" }

    assert handoff, "handed_off_from_id has no foreign key"
    assert_equal parent.options[:on_delete], handoff.options[:on_delete],
                 "the two self-references must behave the same when a row is reaped"
  end
end
