require "test_helper"

# `terminal?` must agree with the `terminal` SQL scope about every end state.
#
# It did not. Rails enum readers return the LABEL, so `status` reads "timed_out"
# while TERMINAL_STATUSES — which the scope's `where` needs — holds the DB value
# "timeout". Only the two members where label != value were affected, and those
# are the two nothing was thought to write, so this read correctly for years.
#
# `status = 'error'` is written in two places (Scenario#count_iteration! on
# MAX_ITERATIONS, ScenarioStepProcessor#process_subflow_step on a missing target),
# so errored runs existed and every `terminal?` guard was open on them.
#
# Found by the idle-sweep spike, which needed to write `timeout` at ~500 runs/day
# and would have turned each of these from rare into routine.
class ScenarioTerminalStatusTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      email: "term-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    sign_in @user
  end

  def workflow_with_one_question(title = "W #{SecureRandom.hex(3)}")
    wf = Workflow.create!(title: title, user: @user)
    q = Steps::Question.create!(workflow: wf, position: 0, title: "First",
                                question: "First?", variable_name: "v_#{SecureRandom.hex(2)}")
    r = Steps::Resolve.create!(workflow: wf, position: 1, title: "Done", resolution_type: "success")
    Transition.create!(step: q, target_step: r, position: 0)
    wf.update!(start_step: q)
    [wf, q]
  end

  def run_on(workflow, step, purpose: "live")
    Scenario.create!(workflow: workflow, user: @user, purpose: purpose, status: "active",
                     started_at: Time.current, current_node_uuid: step.uuid,
                     execution_path: [], results: {}, inputs: {})
  end

  # Writes the DB value straight past the enum writer, the way count_iteration!
  # effectively does, so the test exercises a row as it really lands.
  def force_status!(scenario, db_value, **attrs)
    Scenario.where(id: scenario.id).update_all(status: db_value, **attrs)
    scenario.reload
  end

  # --- the predicate itself ---------------------------------------------------

  test "terminal? is true for every member of TERMINAL_STATUSES" do
    Scenario::TERMINAL_STATUSES.each do |db_value|
      assert_predicate Scenario.new(status: db_value), :terminal?,
                       "#{db_value.inspect} is in TERMINAL_STATUSES but terminal? said false"
    end
  end

  test "terminal? is false for the statuses that are still running" do
    %w[active awaiting_subflow].each do |db_value|
      assert_not Scenario.new(status: db_value).terminal?
    end
  end

  test "the enum reader returns a label that is not the DB value" do
    # The mechanism, pinned. If a future enum entry adds another label != value
    # pair, this is the line that explains why terminal? has to translate.
    assert_equal "timed_out", Scenario.new(status: "timeout").status
    assert_equal "errored",   Scenario.new(status: "error").status
    assert_equal "timeout",   Scenario.statuses["timed_out"]
    assert_equal "error",     Scenario.statuses["errored"]
  end

  test "Ruby and SQL agree about the same row" do
    wf, q = workflow_with_one_question
    %w[timeout error completed stopped].each do |db_value|
      run = force_status!(run_on(wf, q), db_value, completed_at: Time.current)
      assert_includes Scenario.terminal.map(&:id), run.id, "SQL says #{db_value} is terminal"
      assert_predicate run, :terminal?, "Ruby must agree about #{db_value}"
    end
  end

  test "complete? agrees with terminal? without depending on current_node_uuid" do
    wf, q = workflow_with_one_question
    run = force_status!(run_on(wf, q), "error", completed_at: Time.current)

    assert_not_nil run.current_node_uuid, "the row still points at a node — that is the hard case"
    assert_predicate run, :complete?, "a run that died on the iteration limit is over"
  end

  # --- the guards that were open ----------------------------------------------

  test "stop_frame! does not overwrite the outcome of an errored run" do
    wf, q = workflow_with_one_question
    run = force_status!(run_on(wf, q), "error", outcome: "error", completed_at: Time.current)

    run.stop_frame!

    assert_equal "error", run.reload.outcome,
                 "`return if terminal?` has to protect the record of how the run really ended"
    assert_equal "errored", run.status
  end

  test "stop_frame! does not overwrite the outcome of a timed-out run" do
    wf, q = workflow_with_one_question
    run = force_status!(run_on(wf, q), "timeout", outcome: "abandoned", completed_at: 2.days.ago)
    stamped = run.completed_at

    run.stop_frame!

    assert_equal "abandoned", run.reload.outcome
    assert_equal "timed_out", run.status, "a swept run must not be re-settled as stopped"
    assert_equal stamped.to_i, run.completed_at.to_i, "nor restamped"
  end

  test "an errored handoff branch is not reported as the live head" do
    wf, q = workflow_with_one_question
    source = run_on(wf, q)
    errored = Scenario.create!(workflow: wf, user: @user, purpose: "live", status: "active",
                               handed_off_from_id: source.id, started_at: 1.hour.ago,
                               execution_path: [], results: {}, inputs: {})
    force_status!(errored, "error", outcome: "error", completed_at: Time.current)

    assert_predicate source.reload.live_handed_off_to, :terminal?,
                     "a dead branch must not be selected as where the run lives"
    assert_predicate source.run_head, :terminal?,
                     "so run_head must not hand the runner a frame it thinks is answerable"
  end

  # --- what the agent actually sees -------------------------------------------

  test "the runner does not offer an answerable card on an errored run" do
    wf, q = workflow_with_one_question
    run = force_status!(run_on(wf, q), "error", outcome: "error", completed_at: Time.current)

    get step_scenario_path(run)

    assert_response :success
    assert_no_match(/name="answer"/, response.body,
                    "a run that died on the iteration limit is not answerable")
  end

  test "the runner does not offer an answerable card on a timed-out run" do
    wf, q = workflow_with_one_question
    run = force_status!(run_on(wf, q), "timeout", outcome: "abandoned", completed_at: 2.days.ago)

    get step_scenario_path(run)

    assert_response :success
    assert_no_match(/name="answer"/, response.body,
                    "nor is one the idle sweep settled")
  end
end
