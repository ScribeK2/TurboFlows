require "test_helper"

# The idle sweep: what stops abandoned runs accumulating forever.
#
# Both cleanup scopes need `terminal` AND a `completed_at`, and nothing ever
# moved a run out of `active`/`awaiting_subflow`. Agents close the tab rather
# than clicking Cancel, so the common ending produced an immortal row — 52% of
# rows in a dev database.
#
# The hazard this file exists to guard is in the CLOCK, not the settling.
# `belongs_to :parent_scenario` has no `touch:`, so a parent parked on a LIVE
# sub-flow has a clock that stopped when it parked, and `run_head` returns that
# parent. Anything keyed on one frame settles runs an agent is still working.
# `test_a_parked_parent_with_a_live_child_is_not_swept` is the non-negotiable
# test here.
class IdleScenarioSweepTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      email: "sweep-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    sign_in @user
  end

  # --- fixtures ---------------------------------------------------------------

  def terminal_workflow(title = "W #{SecureRandom.hex(3)}", question_title: "First")
    wf = Workflow.create!(title: title, user: @user)
    q = Steps::Question.create!(workflow: wf, position: 0, title: question_title,
                                question: "#{question_title}?", variable_name: "v_#{SecureRandom.hex(2)}")
    r = Steps::Resolve.create!(workflow: wf, position: 1, title: "Done", resolution_type: "success")
    Transition.create!(step: q, target_step: r, position: 0)
    wf.update!(start_step: q)
    [wf, q]
  end

  def handing_off_workflow(title, target:)
    wf = Workflow.create!(title: title, user: @user)
    q = Steps::Question.create!(workflow: wf, position: 0, title: "First",
                                question: "First?", variable_name: "carried")
    ho = Steps::SubFlow.create!(workflow: wf, position: 1, title: "Continue in #{target.title}",
                                sub_flow_workflow_id: target.id, sub_flow_returns: false)
    Transition.create!(step: q, target_step: ho, position: 0)
    wf.update!(start_step: q)
    [wf, q]
  end

  def start_run(workflow, step, purpose: "live")
    Scenario.create!(workflow: workflow, user: @user, purpose: purpose, status: "active",
                     started_at: Time.current, current_node_uuid: step.uuid,
                     execution_path: [], results: {}, inputs: {})
  end

  # updated_at is the clock under test, so set it without bumping it again.
  def age!(scenario, ago)
    Scenario.where(id: scenario.id).update_all(updated_at: ago)
    scenario.reload
  end

  def parked_parent_with_child(parent_age:, child_age:)
    pwf, pq = terminal_workflow
    cwf, cq = terminal_workflow
    parent = start_run(pwf, pq)
    parent.update!(status: "awaiting_subflow", resume_node_uuid: pq.uuid)
    child = Scenario.create!(workflow: cwf, user: @user, purpose: "live", status: "active",
                             parent_scenario: parent, started_at: Time.current,
                             current_node_uuid: cq.uuid, execution_path: [], results: {}, inputs: {})
    age!(parent, parent_age)
    age!(child, child_age)
    [parent, child]
  end

  # --- the hazard -------------------------------------------------------------

  test "a parked parent with a live child is not swept" do
    parent, child = parked_parent_with_child(parent_age: 48.hours.ago, child_age: 1.minute.ago)

    assert_equal 0, Scenario.sweep_idle_runs, "the agent is working inside the sub-flow"
    assert_not_predicate parent.reload, :terminal?, "settling this would end a live run"
    assert_not_predicate child.reload, :terminal?
  end

  test "the parent alone looks idle, which is why the clock spans the run" do
    parent, child = parked_parent_with_child(parent_age: 48.hours.ago, child_age: 1.minute.ago)

    assert_operator parent.updated_at, :<, 24.hours.ago, "the frame's own clock stopped when it parked"
    assert_not parent.run_idle?, "but the run's has not"
    assert_equal child.updated_at.to_i, parent.run_last_activity.to_i
  end

  # --- the ordinary case ------------------------------------------------------

  test "a run idle past the threshold is settled as timeout/abandoned" do
    wf, q = terminal_workflow
    run = start_run(wf, q)
    age!(run, 48.hours.ago)
    last_activity = run.updated_at

    assert_equal 1, Scenario.sweep_idle_runs

    run.reload
    assert_equal "timed_out", run.status, "status says it is over"
    assert_equal "abandoned", run.outcome, "outcome says how, and feeds drop-off analysis"
    assert_equal last_activity.to_i, run.completed_at.to_i,
                 "the run ended when it was last touched, not when the sweep noticed"
    assert_nil run.current_node_uuid
    assert_predicate run, :complete?, "so the runner never offers an answerable card"
  end

  test "a fresh run is left alone" do
    wf, q = terminal_workflow
    run = start_run(wf, q)

    assert_equal 0, Scenario.sweep_idle_runs
    assert_predicate run.reload, :active?
  end

  test "a whole dead sub-flow run is settled, parent and child together" do
    parent, child = parked_parent_with_child(parent_age: 48.hours.ago, child_age: 48.hours.ago)

    assert_equal 1, Scenario.sweep_idle_runs, "one run, not two frames"
    assert_predicate parent.reload, :terminal?
    assert_predicate child.reload, :terminal?
    assert_equal "abandoned", parent.outcome
  end

  test "a handoff chain is settled from either end and counted once" do
    target, = terminal_workflow("T #{SecureRandom.hex(2)}", question_title: "Second")
    source, source_q = handing_off_workflow("S #{SecureRandom.hex(2)}", target: target)
    run = start_run(source, source_q)
    post next_step_scenario_path(run), params: { answer: "yes" },
                                       headers: { "Accept" => "text/vnd.turbo-stream.html" }
    handed_to = Scenario.find_by(workflow: target, user: @user)
    assert_not_nil handed_to, "the handoff must have produced a run on the target"

    age!(run, 48.hours.ago)
    age!(handed_to, 48.hours.ago)

    assert_equal 1, Scenario.sweep_idle_runs,
                 "the source is already terminal; the run is one run across the handoff"
    assert_predicate handed_to.reload, :terminal?
  end

  test "a live handoff head keeps its already-terminal source from being re-counted" do
    target, = terminal_workflow("T #{SecureRandom.hex(2)}", question_title: "Second")
    source, source_q = handing_off_workflow("S #{SecureRandom.hex(2)}", target: target)
    run = start_run(source, source_q)
    post next_step_scenario_path(run), params: { answer: "yes" },
                                       headers: { "Accept" => "text/vnd.turbo-stream.html" }
    handed_to = Scenario.find_by(workflow: target, user: @user)

    age!(run, 48.hours.ago)
    age!(handed_to, 1.minute.ago)

    assert_equal 0, Scenario.sweep_idle_runs, "the run is alive downstream of the old frame"
    assert_not_predicate handed_to.reload, :terminal?
  end

  # --- idempotence and safety -------------------------------------------------

  test "a second pass is a no-op and does not restamp" do
    wf, q = terminal_workflow
    run = start_run(wf, q)
    age!(run, 48.hours.ago)
    Scenario.sweep_idle_runs
    stamped = run.reload.completed_at

    assert_equal 0, Scenario.sweep_idle_runs
    assert_equal stamped.to_i, run.reload.completed_at.to_i
  end

  test "an already-terminal frame keeps the outcome it earned" do
    parent, child = parked_parent_with_child(parent_age: 48.hours.ago, child_age: 48.hours.ago)
    child.update!(status: "completed", outcome: "resolved", completed_at: 47.hours.ago)
    age!(child, 48.hours.ago)

    Scenario.sweep_idle_runs

    assert_equal "resolved", child.reload.outcome, "a finished sub-flow is not abandoned"
    assert_equal "abandoned", parent.reload.outcome, "but the parent nobody resumed is"
  end

  test "a run whose lock_version moved before the pass is still settled" do
    wf, q = terminal_workflow
    run = start_run(wf, q)
    age!(run, 48.hours.ago)
    Scenario.where(id: run.id).update_all(lock_version: run.lock_version + 5)

    assert_equal 1, Scenario.sweep_idle_runs,
                 "the sweep re-reads each run, so a bump before it looks is not a conflict"
    assert_predicate run.reload, :terminal?
  end

  test "a StaleObjectError on one run does not abort the batch" do
    wf_a, q_a = terminal_workflow
    wf_b, q_b = terminal_workflow
    contended = start_run(wf_a, q_a)
    ordinary  = start_run(wf_b, q_b)
    age!(contended, 48.hours.ago)
    age!(ordinary, 48.hours.ago)

    # The genuine race — an agent saving between the sweep's read and its write —
    # cannot be produced from a single-threaded test, because the sweep re-reads.
    # So raise it where it would be raised.
    contended_id = contended.id
    Scenario.class_eval do
      alias_method :time_out_frame_without_race!, :time_out_frame!
      define_method(:time_out_frame!) do |at|
        raise ActiveRecord::StaleObjectError.new(self, "update") if id == contended_id

        time_out_frame_without_race!(at)
      end
    end

    begin
      swept = Scenario.sweep_idle_runs
    ensure
      Scenario.class_eval do
        remove_method :time_out_frame!
        alias_method :time_out_frame!, :time_out_frame_without_race!
        remove_method :time_out_frame_without_race!
      end
    end

    assert_equal 1, swept, "the uncontended run must still be settled and counted"
    assert_predicate ordinary.reload, :terminal?
    assert_not_predicate contended.reload, :terminal?, "left for the next pass, with a fresh clock"
  end

  # --- what it buys -----------------------------------------------------------

  test "a swept run becomes collectable by the existing retention job" do
    wf, q = terminal_workflow
    run = start_run(wf, q, purpose: "live")
    age!(run, 200.days.ago)

    Scenario.sweep_idle_runs

    assert_includes Scenario.stale_live.map(&:id), run.id,
                    "settling is the whole point: cleanup can only see runs with a completed_at"
  end

  test "simulations are swept too, on their own retention clock" do
    wf, q = terminal_workflow
    run = start_run(wf, q, purpose: "simulation")
    age!(run, 30.days.ago)

    Scenario.sweep_idle_runs

    assert_includes Scenario.stale_simulations.map(&:id), run.id,
                    "nobody finishes a test run; not sweeping them leaks the largest pool"
  end

  test "dry_run reports without writing" do
    wf, q = terminal_workflow
    run = start_run(wf, q)
    age!(run, 48.hours.ago)

    assert_equal 1, Scenario.sweep_idle_runs(dry_run: true)
    assert_predicate run.reload, :active?, "the count is for reading before the first real pass"
    assert_equal 1, Scenario.sweep_idle_runs
  end

  test "the threshold is configurable" do
    wf, q = terminal_workflow
    run = start_run(wf, q)
    age!(run, 3.hours.ago)

    assert_equal 0, Scenario.sweep_idle_runs, "not idle at the 24h default"

    ENV["SCENARIO_IDLE_TIMEOUT_HOURS"] = "1"
    begin
      assert_equal 1, Scenario.sweep_idle_runs
    ensure
      ENV.delete("SCENARIO_IDLE_TIMEOUT_HOURS")
    end
  end

  test "outstanding_non_terminal is what says whether the leak is closed" do
    wf, q = terminal_workflow
    run = start_run(wf, q)
    age!(run, 48.hours.ago)

    assert_equal 1, Scenario.outstanding_non_terminal
    Scenario.sweep_idle_runs
    assert_equal 0, Scenario.outstanding_non_terminal
  end

  test "the job settles idle runs" do
    wf, q = terminal_workflow
    run = start_run(wf, q)
    age!(run, 48.hours.ago)

    SweepIdleScenariosJob.perform_now

    assert_predicate run.reload, :terminal?
  end
end
