require "test_helper"

# An errored run has to be a properly recorded ending, not just a status.
#
# Both writers set `status = 'error'` and stopped there, so the row was terminal
# with a NULL completed_at. Both cleanup scopes filter on
# `completed_at < N.days.ago`, and `NULL < date` is never true in SQL, so no
# errored run was ever collected — a leak distinct from the abandoned-run one,
# and invisible precisely because the rows read as terminal everywhere else.
#
# Found by driving Scenario#count_iteration! for real while verifying the
# terminal?/enum fix.
class ScenarioErrorCompletionTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "errc-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    @workflow = Workflow.create!(title: "Err #{SecureRandom.hex(3)}", user: @user)
    Steps::Resolve.create!(workflow: @workflow, position: 0, title: "Done",
                           resolution_type: "success")
  end

  # NB: not `run` — that is Minitest::Test#run, and overriding it silently
  # skips setup.
  def new_run(purpose: "live", started: 10.minutes.ago)
    Scenario.create!(workflow: @workflow, user: @user, purpose: purpose, status: "active",
                     started_at: started, execution_path: [], results: {}, inputs: {})
  end

  # --- writer 1: the iteration limit -----------------------------------------

  test "exceeding MAX_ITERATIONS records a completion, not just a status" do
    s = new_run
    s.iteration_count = Scenario::MAX_ITERATIONS

    assert_raises(Scenario::ScenarioIterationLimit) { s.send(:count_iteration!) }

    s.reload
    assert_equal "errored", s.status
    assert_predicate s, :terminal?
    assert_not_nil s.completed_at, "without this the row can never be collected"
    assert_equal "error", s.outcome
    assert_operator s.duration_seconds, :>=, 0, "an errored run still took time"
    assert_match(/maximum iterations/, s.results["_error"])
  end

  # --- writer 2: a sub-flow target that no longer exists ----------------------

  test "a missing sub-flow target records a completion, not just a status" do
    target = Workflow.create!(title: "Target #{SecureRandom.hex(3)}", user: @user)
    step = Steps::SubFlow.create!(workflow: @workflow, position: 1, title: "Into target",
                                  sub_flow_workflow_id: target.id)
    target.destroy
    s = new_run

    outcome = ScenarioStepProcessor.new(s).process(step, nil, {})
    assert_predicate outcome, :halted?, "a missing target cannot be run"

    s.reload
    assert_equal "errored", s.status
    assert_not_nil s.completed_at, "the same leak, from the other writer"
    assert_equal "error", s.outcome
    assert_match(/not found/, s.results["_error"])
  end

  # --- the leak itself --------------------------------------------------------

  test "an old errored run is collectable by the retention job" do
    # The stamp has to come from the real writer, not from the test, or this
    # passes with the bug still in place. travel_to makes count_iteration! itself
    # record an ending 200 days ago.
    s = nil
    travel_to 200.days.ago do
      s = new_run(started: 1.minute.ago)
      s.iteration_count = Scenario::MAX_ITERATIONS
      assert_raises(Scenario::ScenarioIterationLimit) { s.send(:count_iteration!) }
    end

    assert_includes Scenario.stale_live.map(&:id), s.reload.id,
                    "a terminal run with a stamped completed_at is what cleanup can see"
  end

  test "an errored run with a NULL completed_at is invisible to both scopes" do
    # Pins the mechanism, so the next person understands why the stamp matters.
    s = new_run(started: 200.days.ago)
    Scenario.where(id: s.id).update_all(status: "error", completed_at: nil)

    assert_includes Scenario.terminal.map(&:id), s.id, "terminal by status"
    assert_not_includes Scenario.stale_live.map(&:id), s.id, "but NULL < date is never true"
    assert_not_includes Scenario.stale_simulations.map(&:id), s.id
  end
end
