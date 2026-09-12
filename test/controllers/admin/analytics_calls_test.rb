require "test_helper"

module Admin
  # Regression: ISSUE-003 — analytics counted every workflow a call passed through as a run
  # Found by /qa on 2026-09-12
  # Report: .gstack/qa-reports/qa-report-localhost-2026-09-12.md
  #
  # Two calls — one handed from Start to Next, one escalated with a returning
  # sub-flow in Next — are four scenario rows. The headline counted all four as
  # runs and averaged their durations separately, so a routed call read as
  # several short ones. It counts calls now; the per-workflow and per-agent tables
  # still count each workflow's own runs.
  class AnalyticsCallsTest < ActionDispatch::IntegrationTest
    setup do
      @admin = User.create!(
        email: "admin-calls-#{SecureRandom.hex(4)}@example.com",
        password: "password123!", password_confirmation: "password123!", role: "admin"
      )
      @start_wf = Workflow.create!(title: "Calls Start #{SecureRandom.hex(3)}", user: @admin)
      @next_wf = Workflow.create!(title: "Calls Next #{SecureRandom.hex(3)}", user: @admin)
      sign_in @admin
    end

    def frame(workflow:, outcome:, started:, finished:, parent: nil, handed_off_from: nil)
      Scenario.create!(workflow: workflow, user: @admin, purpose: "live", status: "completed", outcome: outcome,
                       parent_scenario: parent, handed_off_from: handed_off_from,
                       started_at: started, completed_at: finished,
                       duration_seconds: (finished - started).to_i,
                       execution_path: [], results: {}, inputs: {})
    end

    def two_calls
      t0 = 2.days.ago.change(usec: 0)
      a = frame(workflow: @start_wf, outcome: "transferred", started: t0, finished: t0 + 1.minute)
      frame(workflow: @next_wf, handed_off_from: a, outcome: "resolved",
            started: t0 + 1.minute, finished: t0 + 5.minutes)
      c = frame(workflow: @start_wf, outcome: "escalated", started: t0 + 1.hour, finished: t0 + 63.minutes)
      frame(workflow: @next_wf, parent: c, outcome: "resolved",
            started: t0 + 1.hour + 30.seconds, finished: t0 + 62.minutes)
    end

    def stat_value(label)
      stat(label).at_css(".stat-cell__value").text.strip
    end

    def stat(label)
      css_select(".stat-cell").index_by { it.at_css(".stat-cell__label").text.strip }.fetch(label)
    end

    test "the headline counts calls, not every workflow a call passed through" do
      two_calls

      get admin_analytics_path(user_id: @admin.id)

      assert_response :success
      assert_equal "2", stat_value("Total Calls")
      assert_equal "100.0%", stat_value("Completion Rate")
      assert_match "of 2 finished calls", stat("Completion Rate").text
      assert_equal "4m 0s", stat_value("Avg Duration"), "(5m + 3m) / 2 — each call from start to end"
      assert_equal "50.0%", stat_value("Escalation Rate")
    end

    test "the outcome breakdown is how calls ended, with no row for a handoff along the way" do
      two_calls

      get admin_analytics_path(user_id: @admin.id)

      rows = css_select("#outcome-breakdown tbody tr").to_h do |tr|
        cells = tr.css("td")
        [cells[0].text.strip, cells[1].text.strip]
      end
      assert_equal({ "Resolved" => "1", "Escalated" => "1" }, rows)
    end

    test "calls over time count each call once, on the day it started" do
      two_calls

      get admin_analytics_path(user_id: @admin.id)

      assert_select ".card", text: /Calls Over Time/ do
        assert_select "tbody tr", 1
        assert_select "tbody td span.tabular-nums", text: "2"
      end
    end

    test "the workflow usage table still counts each workflow's own runs" do
      two_calls

      get admin_analytics_path(user_id: @admin.id)

      usage = css_select("#workflow-usage tbody tr").to_h do |tr|
        cells = tr.css("td").map { it.text.strip }
        [cells[0], cells[1]]
      end
      assert_equal "2", usage.fetch(@start_wf.title)
      assert_equal "2", usage.fetch(@next_wf.title), "the handed-to run and the sub-flow run are Next's runs"
    end

    test "filtering by workflow counts the calls that started there" do
      two_calls

      get admin_analytics_path(user_id: @admin.id, workflow_id: @next_wf.id)

      assert_equal "0", stat_value("Total Calls")
    end

    # --- all time --------------------------------------------------------------

    def rollup(day, workflow:, outcome:, runs:, calls:, call_duration_sum: 0, call_duration_count: 0)
      ScenarioRollup.create!(workflow: workflow, day: day, purpose: "live", outcome: outcome,
                             runs_count: runs, duration_sum_seconds: 0, duration_count: 0,
                             calls_count: calls, call_duration_sum_seconds: call_duration_sum,
                             call_duration_count: call_duration_count)
    end

    test "all time counts calls from the rollups" do
      day = 400.days.ago.to_date
      rollup(day, workflow: @start_wf, outcome: "transferred", runs: 5, calls: 0)
      rollup(day, workflow: @start_wf, outcome: "resolved", runs: 1, calls: 4,
                  call_duration_sum: 800, call_duration_count: 4)
      rollup(day, workflow: @next_wf, outcome: "resolved", runs: 4, calls: 0)

      get admin_analytics_path(range: "all")

      assert_equal "4", stat_value("Total Calls")
      assert_equal "3m 20s", stat_value("Avg Duration")
      assert_select "#outcome-breakdown td", text: "Transferred", count: 0
    end

    # Days rolled before calls were counted carry zero calls. Saying where the
    # count begins is what keeps a shorter history from reading as less activity.
    test "all time says from when calls were counted" do
      rollup(500.days.ago.to_date, workflow: @start_wf, outcome: "resolved", runs: 3, calls: 0)
      counted_from = 20.days.ago.to_date
      rollup(counted_from, workflow: @start_wf, outcome: "resolved", runs: 1, calls: 1)

      get admin_analytics_path(range: "all")

      assert_match "Calls are counted from #{I18n.l(counted_from, format: :long)}", response.body
    end
  end
end
