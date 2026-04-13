require "test_helper"

class ScenarioExecutionConcernTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "exec-concern-#{SecureRandom.hex(4)}@test.com", password: "password123456")
    @workflow = Workflow.create!(title: "Concern Test WF", user: @user)
    @question = Steps::Question.create!(
      workflow: @workflow, title: "Q1", position: 0,
      variable_name: "q1", question: "What?"
    )
    @resolve = Steps::Resolve.create!(
      workflow: @workflow, title: "Done", position: 1, resolution_type: "success"
    )
    Transition.create!(step: @question, target_step: @resolve, position: 0)
    @workflow.update!(start_step: @question)
  end

  def build_scenario(start_step, **overrides)
    Scenario.create!({
      workflow: @workflow, user: @user, purpose: "simulation",
      status: "active", current_node_uuid: start_step.uuid,
      execution_path: [], results: {}, inputs: {}
    }.merge(overrides))
  end

  # ---------------------------------------------------------------------------
  # record_step_started
  # ---------------------------------------------------------------------------

  test "record_step_started sets step_started_at_pending to current time" do
    scenario = build_scenario(@question)
    freeze_time do
      scenario.record_step_started
      assert_equal Time.current.iso8601(3), scenario.step_started_at_pending
    end
  end

  # ---------------------------------------------------------------------------
  # record_step_ended
  # ---------------------------------------------------------------------------

  test "record_step_ended stamps ended_at and duration_seconds on last path entry" do
    scenario = build_scenario(@question)
    started = 5.seconds.ago
    scenario.execution_path = [{ "step_title" => "Q1", "started_at" => started.iso8601(3) }]
    scenario.save!

    freeze_time do
      scenario.record_step_ended
      last = scenario.execution_path.last
      assert_predicate last["ended_at"], :present?, "Should set ended_at"
      assert_in_delta (Time.current - started).round(1), last["duration_seconds"], 0.2
    end
  end

  test "record_step_ended is no-op when execution_path is blank" do
    scenario = build_scenario(@question, execution_path: [])
    assert_nothing_raised { scenario.record_step_ended }
  end

  test "record_step_ended is no-op when last entry has no started_at" do
    scenario = build_scenario(@question)
    scenario.execution_path = [{ "step_title" => "Q1" }]
    scenario.save!

    scenario.record_step_ended
    assert_nil scenario.execution_path.last["ended_at"]
  end

  test "record_step_ended swallows StaleObjectError gracefully" do
    scenario = build_scenario(@question)
    scenario.execution_path = [{ "step_title" => "Q1", "started_at" => 2.seconds.ago.iso8601(3) }]
    scenario.save!

    # Simulate a concurrent modification by bumping lock_version in the DB
    Scenario.where(id: scenario.id).update_all(lock_version: scenario.lock_version + 1)

    # Should not raise — swallows StaleObjectError
    assert_nothing_raised { scenario.record_step_ended }
  end

  # ---------------------------------------------------------------------------
  # record_completion
  # ---------------------------------------------------------------------------

  test "record_completion sets outcome, completed_at and duration_seconds" do
    scenario = build_scenario(@question)
    start_time = Time.current
    scenario.started_at = start_time
    scenario.save!

    travel 10.seconds do
      scenario.record_completion("resolved")
      assert_equal "resolved", scenario.outcome
      assert_equal Time.current, scenario.completed_at
      assert_in_delta 10, scenario.duration_seconds, 1
    end
  end

  test "record_completion without started_at does not set duration_seconds" do
    scenario = build_scenario(@question)
    scenario.update_columns(started_at: nil)

    scenario.record_completion("abandoned")
    assert_equal "abandoned", scenario.outcome
    assert_nil scenario.duration_seconds
  end

  # ---------------------------------------------------------------------------
  # resolve_at_current_step
  # ---------------------------------------------------------------------------

  test "resolve_at_current_step marks last path entry as resolved and completes scenario" do
    scenario = build_scenario(@question)
    scenario.execution_path = [{ step_title: "Q1", step_uuid: @question.uuid }]
    scenario.started_at = 5.seconds.ago
    scenario.save!

    scenario.resolve_at_current_step(@question)

    assert scenario.execution_path.last[:resolved]
    assert_equal "resolved", scenario.outcome
    assert_equal "completed", scenario.status
    assert_nil scenario.current_node_uuid
    assert_equal @question.uuid, scenario.results["_resolution"]["resolved_at_step"]
  end

  # ---------------------------------------------------------------------------
  # advance_to_next_step
  # ---------------------------------------------------------------------------

  test "advance_to_next_step follows transition to next step" do
    scenario = build_scenario(@question)
    scenario.results = {}
    scenario.save!

    scenario.advance_to_next_step(@question)
    assert_equal @resolve.uuid, scenario.current_node_uuid
  end

  test "advance_to_next_step sets nil when no outgoing transitions" do
    scenario = build_scenario(@resolve)
    scenario.results = {}
    scenario.save!

    scenario.advance_to_next_step(@resolve)
    assert_nil scenario.current_node_uuid
  end

  # ---------------------------------------------------------------------------
  # determine_next_step_index (legacy index-based resolution)
  # ---------------------------------------------------------------------------

  test "determine_next_step_index returns next index by default" do
    scenario = build_scenario(@question)
    scenario.current_step_index = 0

    next_idx = scenario.determine_next_step_index(@question, {})
    assert_equal 1, next_idx
  end

  # ---------------------------------------------------------------------------
  # execute_with_limits (batch execution)
  # ---------------------------------------------------------------------------

  test "execute_with_limits processes workflow to completion" do
    scenario = build_scenario(@question, inputs: { "q1" => "test answer" })

    scenario.execute_with_limits

    assert_equal "completed", scenario.status
    assert_predicate scenario.execution_path, :any?, "Should have execution path entries"
    assert_equal "test answer", scenario.results["Q1"]
  end

  test "execute_with_limits records action steps in execution path" do
    wf = Workflow.create!(title: "Multi Step WF", user: @user)
    a1 = Steps::Action.create!(workflow: wf, title: "Step A", position: 0)
    a2 = Steps::Action.create!(workflow: wf, title: "Step B", position: 1)
    r  = Steps::Resolve.create!(workflow: wf, title: "End", position: 2, resolution_type: "success")
    Transition.create!(step: a1, target_step: a2, position: 0)
    Transition.create!(step: a2, target_step: r, position: 0)
    wf.update!(start_step: a1)

    scenario = Scenario.create!(
      workflow: wf, user: @user, purpose: "simulation",
      status: "active", current_node_uuid: a1.uuid,
      execution_path: [], results: {}, inputs: {}
    )

    scenario.execute_with_limits

    assert_equal "completed", scenario.status
    # Batch execution records one path entry per step
    assert_equal 3, scenario.execution_path.size
    assert_equal "Step A", scenario.execution_path[0]["step_title"]
    assert_equal "Step B", scenario.execution_path[1]["step_title"]
    assert_equal "End", scenario.execution_path[2]["step_title"]
    assert_equal "Action executed", scenario.results["Step A"]
    assert_equal "Action executed", scenario.results["Step B"]
  end

  # ---------------------------------------------------------------------------
  # build_path_entry (private, but exercised via process_step)
  # ---------------------------------------------------------------------------

  test "build_path_entry uses step_started_at_pending when available" do
    scenario = build_scenario(@question)
    scenario.record_step_started # sets pending timestamp

    # Process a step — build_path_entry should consume the pending timestamp
    scenario.process_step("answer")

    entry = scenario.execution_path.first
    assert_predicate entry["started_at"], :present?, "Path entry should have started_at from pending timestamp"
    assert_nil scenario.step_started_at_pending, "Pending timestamp should be consumed"
  end
end
