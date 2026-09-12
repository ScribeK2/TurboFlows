require "test_helper"

# Regression: ISSUE-003 — analytics counted every workflow a call passed through as a run
# Found by /qa on 2026-09-12
# Report: .gstack/qa-reports/qa-report-localhost-2026-09-12.md
#
# A call starts in one workflow and may pass through several, by sub-flow or by
# handoff, before it ends. The analytics headline counted every workflow a call
# passed through as a run, so two calls read as Total Runs 10. CallStatistics
# counts calls: where each started, how it ended (Scenario#run_ending, in SQL),
# and how long that took.
class CallStatisticsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "calls-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    @start_wf = Workflow.create!(title: "Start #{SecureRandom.hex(3)}", user: @user)
    @next_wf = Workflow.create!(title: "Next #{SecureRandom.hex(3)}", user: @user)
    @t0 = Time.zone.parse("2026-09-01 09:00:00")
  end

  def frame(workflow: @start_wf, parent: nil, handed_off_from: nil, status: "active", outcome: nil,
            started: 0, finished: nil)
    Scenario.create!(workflow: workflow, user: @user, purpose: "live", status: status, outcome: outcome,
                     parent_scenario: parent, handed_off_from: handed_off_from,
                     started_at: @t0 + started.seconds, completed_at: finished && (@t0 + finished.seconds),
                     execution_path: [], results: {}, inputs: {})
  end

  def stats(scope = Scenario.where(user: @user))
    CallStatistics.new(scope)
  end

  # One call handed on twice, one escalated with a returning sub-flow inside it,
  # and one still going.
  def three_calls
    a = frame(status: "completed", outcome: "transferred", finished: 60)
    b = frame(workflow: @next_wf, handed_off_from: a, status: "completed", outcome: "transferred",
              started: 60, finished: 120)
    frame(workflow: @next_wf, handed_off_from: b, status: "completed", outcome: "resolved", started: 120, finished: 300)
    d = frame(status: "completed", outcome: "escalated", started: 1000, finished: 1100)
    frame(workflow: @next_wf, parent: d, status: "completed", outcome: "resolved", started: 1010, finished: 1050)
    frame(started: 2000)
  end

  test "a call is counted once, however many workflows it passed through" do
    three_calls

    assert_equal 3, stats.total
    assert_equal({ "resolved" => 1, "escalated" => 1, nil => 1 }, stats.outcome_breakdown)
    assert_equal 2, stats.finished
    assert_equal 2, stats.completed
    assert_equal 1, stats.escalated
  end

  test "a call lasts from where it started to where it ended" do
    three_calls

    assert_equal 200, stats.average_duration_seconds, "(300 + 100) / 2; the call still going has no duration yet"
  end

  test "a call belongs to the workflow it started in" do
    three_calls

    assert_equal 3, stats(Scenario.where(user: @user, workflow: @start_wf)).total
    assert_equal 0, stats(Scenario.where(user: @user, workflow: @next_wf)).total,
                 "handed-to and sub-flow frames are part of a call, not calls"
  end

  test "calls are grouped over time by the day they started" do
    frame(status: "completed", outcome: "resolved", finished: 10)
    frame(status: "completed", outcome: "resolved", started: 1.day.to_i, finished: 1.day.to_i + 10)
    frame(status: "completed", outcome: "resolved", started: 1.day.to_i + 60, finished: 1.day.to_i + 70)

    assert_equal({ @t0.to_date => 1, (@t0 + 1.day).to_date => 2 }, stats.over_time(weekly: false))
    assert_equal({ @t0.to_date.beginning_of_week => 3 }, stats.over_time(weekly: true))
  end

  # The results page reads Scenario#run_ending and the headline reads this SQL.
  # If they disagreed, one call would end one way on its results page and another
  # in analytics, and nothing else would notice.
  test "the ending chosen in SQL is Scenario#run_ending, shape by shape" do
    # completed after two handoffs
    a = frame(status: "completed", outcome: "transferred", finished: 10)
    b = frame(handed_off_from: a, status: "completed", outcome: "transferred", started: 10, finished: 20)
    frame(handed_off_from: b, status: "completed", outcome: "resolved", started: 20, finished: 30)
    # cancelled after a handoff, which run_head gets wrong
    c = frame(status: "completed", outcome: "transferred", finished: 10)
    frame(handed_off_from: c, status: "stopped", outcome: "abandoned", started: 10, finished: 40)
    # a handoff made from inside a sub-flow
    d = frame(status: "completed", outcome: "transferred", finished: 50)
    e = frame(parent: d, status: "completed", outcome: "transferred", started: 5, finished: 50)
    frame(handed_off_from: e, status: "completed", outcome: "escalated", started: 50, finished: 80)
    # an abandoned sibling beside a live frame
    f = frame(status: "completed", outcome: "transferred", finished: 20)
    frame(handed_off_from: f, status: "stopped", outcome: "abandoned", started: 20, finished: 21)
    frame(handed_off_from: f, started: 21)
    # a live older sibling beside a newer finished one: newest-by-id alone picks wrong
    g = frame(status: "completed", outcome: "transferred", finished: 20)
    frame(handed_off_from: g, started: 20)
    frame(handed_off_from: g, status: "completed", outcome: "resolved", started: 21, finished: 30)
    # a transferred frame whose handed-to run is gone
    frame(status: "completed", outcome: "transferred", finished: 5)
    # a run parked on a returning sub-flow
    h = frame(status: "awaiting_subflow")
    frame(parent: h, started: 5)

    calls = stats.calls

    assert_equal 7, calls.size
    calls.each do |call|
      assert_equal Scenario.find(call.origin_id).run_ending.id, call.ending_id,
                   "the call that started at S#{call.origin_id}"
    end
  end
end
