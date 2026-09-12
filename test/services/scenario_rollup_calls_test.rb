require "test_helper"

# Regression: ISSUE-003 — analytics counted every workflow a call passed through as a run
# Found by /qa on 2026-09-12
# Report: .gstack/qa-reports/qa-report-localhost-2026-09-12.md
#
# "All time" reads the rollups, so they count calls too — or the headline would
# mean calls for the retention window and workflow runs before it. A call is
# rolled up where it started (the origin's workflow and day) with the outcome it
# ended with, beside the per-workflow run counts on the same grain.
class ScenarioRollupCallsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "rollup-calls-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    @start_wf = Workflow.create!(title: "Rollup Start #{SecureRandom.hex(3)}", user: @user)
    @next_wf = Workflow.create!(title: "Rollup Next #{SecureRandom.hex(3)}", user: @user)
    @day = Date.current - 1
    @t0 = @day.to_time(:utc) + 9.hours
  end

  def frame(workflow:, outcome:, started:, finished: nil, handed_off_from: nil, parent: nil, status: "completed")
    Scenario.create!(workflow: workflow, user: @user, purpose: "live", status: status, outcome: outcome,
                     handed_off_from: handed_off_from, parent_scenario: parent,
                     started_at: @t0 + started.seconds, completed_at: finished && (@t0 + finished.seconds),
                     duration_seconds: finished && (finished - started),
                     execution_path: [], results: {}, inputs: {})
  end

  def rollup(workflow, outcome)
    ScenarioRollup.find_by(workflow: workflow, day: @day, purpose: "live", outcome: outcome)
  end

  test "a call is rolled up where it started, with the outcome it ended with" do
    a = frame(workflow: @start_wf, outcome: "transferred", started: 0, finished: 60)
    frame(workflow: @next_wf, handed_off_from: a, outcome: "resolved", started: 60, finished: 300)

    ScenarioRollupBuilder.rebuild!

    call = rollup(@start_wf, "resolved")
    assert_equal 1, call.calls_count
    assert_equal 0, call.runs_count, "no Start run ended resolved; the row exists for the call"
    assert_equal 300, call.call_duration_sum_seconds
    assert_equal 1, call.call_duration_count

    assert_equal([1, 0], rollup(@start_wf, "transferred").then { [it.runs_count, it.calls_count] })
    assert_equal([1, 0], rollup(@next_wf, "resolved").then { [it.runs_count, it.calls_count] })
  end

  test "a returning sub-flow's run is a run, not a call" do
    c = frame(workflow: @start_wf, outcome: "escalated", started: 0, finished: 100)
    frame(workflow: @next_wf, parent: c, outcome: "resolved", started: 10, finished: 50)

    ScenarioRollupBuilder.rebuild!

    assert_equal 1, ScenarioRollup.where(day: @day).sum(:calls_count)
    assert_equal 2, ScenarioRollup.where(day: @day).sum(:runs_count)
  end

  test "a call still going is pending, and settles on a later rebuild inside the window" do
    a = frame(workflow: @start_wf, outcome: "transferred", started: 0, finished: 60)
    head = frame(workflow: @next_wf, handed_off_from: a, status: "active", outcome: nil, started: 60)
    ScenarioRollupBuilder.rebuild!

    assert_equal 1, rollup(@start_wf, ScenarioRollup::PENDING).calls_count

    head.update!(status: "completed", outcome: "resolved", completed_at: @t0 + 200.seconds)
    ScenarioRollupBuilder.rebuild!

    assert_nil rollup(@start_wf, ScenarioRollup::PENDING), "an upsert would have left the pending call behind"
    assert_equal 1, rollup(@start_wf, "resolved").calls_count
  end
end
