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

  test "the outcome breakdown lists the commonest outcome first" do
    frame(status: "completed", outcome: "escalated", finished: 10)
    3.times { |n| frame(status: "completed", outcome: "resolved", started: n, finished: n + 10) }
    2.times { |n| frame(started: n) }

    assert_equal [["resolved", 3], [nil, 2], ["escalated", 1]], stats.outcome_breakdown.to_a
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

  # Every shape a call can take, spread over two days and two weeks.
  def every_shape
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
    # a live origin beside a finished handed-to frame: still going beats finished
    i = frame(started: 30)
    frame(handed_off_from: i, status: "completed", outcome: "resolved", started: 31, finished: 40)
    # ended where it started, the next day
    frame(status: "completed", outcome: "resolved", started: 1.day.to_i, finished: 1.day.to_i + 45)
    # the next week, finishing mid-second
    frame(status: "completed", outcome: "completed", started: 7.days.to_i + 0.25, finished: 7.days.to_i + 10.75)
  end

  # The results page reads Scenario#run_ending and the headline reads this SQL.
  # If they disagreed, one call would end one way on its results page and another
  # in analytics, and nothing else would notice.
  test "the ending chosen in SQL is Scenario#run_ending, shape by shape" do
    every_shape

    calls = stats.calls

    assert_equal 10, calls.size
    calls.each do |call|
      assert_equal Scenario.find(call.origin_id).run_ending.id, call.ending_id,
                   "the call that started at S#{call.origin_id}"
    end
  end

  # The headline adds up in one SQL query what `calls` lists one by one, so the
  # two have to agree on every shape a call can take.
  test "the headline's figures are the calls' figures, shape by shape" do
    every_shape
    calls = stats.calls
    durations = calls.filter_map(&:duration_seconds)
    headline = stats

    assert_equal calls.size, headline.total
    assert_equal calls.count(&:finished?), headline.finished
    assert_equal calls.count { |call| Scenario::COMPLETED_OUTCOMES.include?(call.outcome) }, headline.completed
    assert_equal calls.count { |call| call.outcome == "escalated" }, headline.escalated
    assert_equal calls.group_by(&:outcome).transform_values(&:size), headline.outcome_breakdown
    assert_equal (durations.sum.to_f / durations.size).round, headline.average_duration_seconds
    assert_equal calls.group_by { |call| call.started_at.utc.to_date }.transform_values(&:size),
                 headline.over_time(weekly: false)
    assert_equal calls.group_by { |call| call.started_at.utc.to_date.beginning_of_week }.transform_values(&:size),
                 headline.over_time(weekly: true)
  end

  test "a duration counts whole seconds, as a call's own duration does" do
    frame(status: "completed", outcome: "resolved", started: 0.25, finished: 10.75)

    assert_equal 10, stats.calls.first.duration_seconds
    assert_equal 10, stats.average_duration_seconds, "10.5 seconds is 10, not 11"
  end

  test "a scope with no calls reads as zeros" do
    headline = stats(Scenario.none)

    assert_equal [0, 0, 0, 0, 0], [headline.total, headline.finished, headline.completed, headline.escalated,
                                   headline.average_duration_seconds]
    assert_equal({}, headline.outcome_breakdown)
    assert_equal({}, headline.over_time(weekly: true))
  end

  # Regression: the headline loaded every call into Ruby to count them. On the
  # load-test replica a 90-day /analytics plucked 496k rows and looked up each
  # call's ending by a 496k-id IN list: 6 seconds and 430 MiB a request, and ten
  # managers opening it at once held every Puma thread and pushed the VM into swap.
  test "the headline reads one row per day and outcome, not one per call" do
    30.times { |n| frame(status: "completed", outcome: "resolved", started: n, finished: n + 60) }

    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload unless payload[:name] == "SCHEMA"
    end
    headline = stats
    [headline.total, headline.finished, headline.completed, headline.escalated, headline.outcome_breakdown,
     headline.average_duration_seconds, headline.over_time(weekly: true), headline.over_time(weekly: false)]
    ActiveSupport::Notifications.unsubscribe(subscriber)

    assert_equal 1, statements.size, statements.pluck(:sql).join("\n")
    assert_equal 1, statements.first[:row_count], "30 calls on one day with one outcome"
  end

  # The ending query used to filter on `id IN (origins) OR run_origin_id IN
  # (origins)`. PostgreSQL can't hash an OR of two subqueries once the origin list
  # outgrows work_mem, so it rescanned the list for every row: on the load-test
  # replica (500k runs) /analytics?range=90d timed out while the query ran on, and
  # the rollup over that backlog was cancelled after 45 minutes. SQLite runs the
  # same SQL happily at test sizes, which is why this test checks the shape.
  test "no query ORs a subquery, which PostgreSQL can't hash at scale" do
    three_calls

    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] unless payload[:name] == "SCHEMA"
    end
    stats.calls
    stats.over_time(weekly: true)
    ActiveSupport::Notifications.unsubscribe(subscriber)

    ored = statements.grep(/\bOR\b[^()]*\bIN\s*\(\s*SELECT/i)

    assert_empty ored, "an OR of IN (SELECT ...) rescans the subquery per row on PostgreSQL:\n#{ored.join("\n")}"
  end
end
