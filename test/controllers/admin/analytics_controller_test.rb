require "test_helper"

module Admin
  class AnalyticsControllerTest < ActionDispatch::IntegrationTest
    def setup
      @admin = User.create!(
        email: "admin-analytics-#{SecureRandom.hex(4)}@example.com",
        password: "password123!",
        password_confirmation: "password123!",
        role: "admin"
      )
      @editor = User.create!(
        email: "editor-analytics-#{SecureRandom.hex(4)}@example.com",
        password: "password123!",
        password_confirmation: "password123!",
        role: "editor"
      )
      @regular_user = User.create!(
        email: "user-analytics-#{SecureRandom.hex(4)}@example.com",
        password: "password123!",
        password_confirmation: "password123!",
        role: "user"
      )
      @workflow = Workflow.create!(title: "Analytics Test Workflow", user: @admin)
      Steps::Question.create!(workflow: @workflow, position: 0, uuid: "s1", title: "Q1", question: "Test?")
    end

    # Drop-off is about live agent behaviour. Until the idle sweep existed almost
    # nothing carried outcome "abandoned", so mixing purposes cost nothing; now
    # that abandoned runs are produced at volume, builder test-runs would swamp
    # the signal. See docs/designs/idle-sweep-spike-findings.md.
    def abandoned_run(purpose:, step_title:)
      Scenario.create!(
        workflow: @workflow, user: @admin, purpose: purpose,
        status: "timeout", outcome: "abandoned",
        started_at: 2.days.ago, completed_at: 1.day.ago,
        execution_path: [{ "step_title" => step_title }], results: {}, inputs: {}
      )
    end

    test "drop-off points exclude simulation runs by default" do
      abandoned_run(purpose: "live", step_title: "Real Agent Step")
      abandoned_run(purpose: "simulation", step_title: "Builder Test Step")
      sign_in @admin

      get admin_analytics_path

      assert_response :success
      assert_match "Real Agent Step", response.body
      assert_no_match(/Builder Test Step/, response.body,
                      "an editor abandoning a test run is not agent drop-off")
    end

    test "drop-off points honour an explicit purpose filter" do
      abandoned_run(purpose: "simulation", step_title: "Builder Test Step")
      sign_in @admin

      get admin_analytics_path(purpose: "simulation")

      assert_response :success
      assert_match "Builder Test Step", response.body,
                   "the default must not become a lock — asking for simulations shows them"
    end

    # How a department is doing includes its teams (spec Q37), and the select
    # names every group by its path.
    test "the group filter names groups by path and counts runs in their subgroups" do
      parent = Group.create!(name: "Analytics Dept #{SecureRandom.hex(3)}")
      child = Group.create!(name: "Analytics Team", parent:)
      GroupWorkflow.create!(group: child, workflow: @workflow, is_primary: true)
      elsewhere = Workflow.create!(title: "Analytics Elsewhere", user: @admin)
      [@workflow, elsewhere].each do |workflow|
        Scenario.create!(workflow:, user: @admin, purpose: "live", status: "completed", outcome: "completed",
                         started_at: 2.days.ago, completed_at: 2.days.ago,
                         execution_path: [], results: {}, inputs: {})
      end
      sign_in @admin

      get admin_analytics_path(group_id: parent.id)

      assert_response :success
      assert_select "select[name=group_id] option[selected][value=?]", parent.id.to_s, text: parent.name
      assert_select "select[name=group_id] option[value=?]", child.id.to_s, text: "#{parent.name} / Analytics Team"
      assert_select "table a[href=?]", workflow_path(@workflow)
      assert_select "table a[href=?]", workflow_path(elsewhere), 0
    end

    # A day rolled up since calls were counted (ISSUE-003): each run here is a
    # call on its own, so both counters hold the same numbers.
    def rolled_up_day(day, outcome:, count:, purpose: "live", duration_sum: 0, duration_count: 0)
      ScenarioRollup.create!(
        workflow: @workflow, day: day, purpose: purpose, outcome: outcome,
        runs_count: count, duration_sum_seconds: duration_sum, duration_count: duration_count,
        calls_count: count, call_duration_sum_seconds: duration_sum, call_duration_count: duration_count
      )
    end

    # "All" claimed all time and could not deliver it: runs are deleted at the
    # retention horizon, so the widest raw range was 90 days wearing a wider
    # label. It now reads a different SOURCE — the daily rollups — rather than a
    # wider window on the same one.
    test "the all-time range reads rollups and reaches past the retention horizon" do
      rolled_up_day(400.days.ago.to_date, outcome: "completed", count: 7,
                                          duration_sum: 700, duration_count: 7)
      rolled_up_day(400.days.ago.to_date, outcome: "escalated", count: 3)
      sign_in @admin

      get admin_analytics_path(range: "all")

      assert_response :success
      assert_match(/All time/, response.body)
      assert_match(/10/, response.body, "totals come from rollups, not from surviving runs")
      assert_match(/Daily totals/, response.body,
                   "the page has to say which source it is reading")
    end

    test "the all-time view does not offer filters it cannot honour" do
      rolled_up_day(400.days.ago.to_date, outcome: "completed", count: 1)
      sign_in @admin

      get admin_analytics_path(range: "all")

      assert_response :success
      assert_no_match(/All Agents/, response.body,
                      "a rollup has no per-agent grain, so the control must not be offered")
      assert_no_match(/All Groups/, response.body)
    end

    test "panels with no rollup behind them say so rather than looking empty" do
      rolled_up_day(400.days.ago.to_date, outcome: "completed", count: 1)
      sign_in @admin

      get admin_analytics_path(range: "all")

      assert_response :success
      assert_match(/Not available for all time/, response.body,
                   "an empty table reads as 'nobody did anything', which is a different claim")
    end

    test "a range within retention still reads runs and keeps every filter" do
      sign_in @admin

      get admin_analytics_path(range: "90d")

      assert_response :success
      assert_match(/All Agents/, response.body, "raw mode keeps the run-level filters")
      assert_match(/Individual runs, with every filter/, response.body)
    end

    # The seam is explicit precisely so a CSV of the last 90 days can never be
    # handed over labelled "all time" — that is the lie being removed.
    test "CSV export from the all-time view redirects rather than mislabelling itself" do
      sign_in @admin

      get admin_analytics_path(range: "all", format: :csv)

      assert_redirected_to admin_analytics_path(range: "90d")
      assert_match(/individual runs/i, flash[:alert])
    end

    # Stage 5 fixes (Q5): outcomes are plain text beside hued bars, Busiest Hours
    # ranks by length not colour, card subtitles are not empty-state copy, and the
    # range hint no longer pushes Purpose out of line with Date Range.
    test "outcomes read as text, busiest hours are one colour, subtitles and filters line up" do
      Scenario.create!(workflow: @workflow, user: @admin, inputs: {}, purpose: "live", status: "completed",
                       outcome: "completed", started_at: 1.day.ago, completed_at: 1.day.ago + 30.seconds,
                       duration_seconds: 30)
      sign_in @admin

      get admin_analytics_path

      assert_response :success
      assert_select "#outcome-breakdown td", text: "Completed"
      assert_select "#outcome-breakdown .badge", 0
      assert_select "#outcome-breakdown .analytics-bar--completed", 1
      assert_select "#busiest-hours .analytics-bar", minimum: 1
      assert_select "#busiest-hours .analytics-bar:not(.analytics-bar--default)", 0
      assert_select ".card__header .empty-state__text", 0
      assert_select ".card__header .analytics-card__subtitle", 2
      assert_select "form.card > p.form-hint", 1
      assert_select "form.card > div.flex p.form-hint", 0
    end

    # A run with no outcome is still going, not "Unknown" (spec Q66), and a
    # handoff is a sub-flow that doesn't return, so it takes that hue.
    test "a run still going reads In progress, and a handoff gets its own bar" do
      Scenario.create!(workflow: @workflow, user: @admin, purpose: "live", status: "active",
                       started_at: 1.hour.ago, execution_path: [], results: {}, inputs: {})
      Scenario.create!(workflow: @workflow, user: @admin, purpose: "live", status: "completed", outcome: "transferred",
                       started_at: 1.hour.ago, completed_at: 50.minutes.ago, execution_path: [], results: {}, inputs: {})
      sign_in @admin

      get admin_analytics_path(workflow_id: @workflow.id)

      assert_select "#outcome-breakdown td", text: "In progress"
      assert_select "#outcome-breakdown td", text: "Unknown", count: 0
      assert_select "#outcome-breakdown .analytics-bar--transferred", 1
    end

    def record_run(outcome:, status: "completed", user: @admin)
      Scenario.create!(workflow: @workflow, user: user, purpose: "live", status: status, outcome: outcome,
                       started_at: 1.day.ago, completed_at: (1.day.ago + 30.seconds if outcome),
                       execution_path: [], results: {}, inputs: {})
    end

    # A run still going has not failed to complete (spec Q67, Q71), and escalating
    # or handing off are endings a workflow is built to reach (Q72, Q73).
    test "rates count only finished runs, and escalated and handed-off runs count as completed" do
      record_run(outcome: "resolved")
      record_run(outcome: "escalated")
      record_run(outcome: "transferred")
      record_run(outcome: "abandoned")
      record_run(outcome: nil, status: "active")
      sign_in @admin

      get admin_analytics_path(workflow_id: @workflow.id)

      cells = css_select(".stat-cell").index_by { it.at_css(".stat-cell__label").text.strip }
      assert_equal "5", cells["Total Calls"].at_css(".stat-cell__value").text.strip
      assert_equal "75.0%", cells["Completion Rate"].at_css(".stat-cell__value").text.strip
      assert_equal "25.0%", cells["Escalation Rate"].at_css(".stat-cell__value").text.strip
      assert_match "of 4 finished calls", cells["Completion Rate"].text

      usage = css_select("#workflow-usage tbody tr").first.css("td").map { it.text.strip }
      assert_equal ["5", "75.0%"], usage[1, 2]
      assert_equal "25.0%", usage[4]

      agent = css_select("#agent-performance tbody tr").first.css("td").map { it.text.strip }
      assert_equal "3", agent[2], "resolved, escalated and transferred"
    end

    test "a workflow with no finished runs shows a dash, not 0%" do
      record_run(outcome: nil, status: "active")
      sign_in @admin

      get admin_analytics_path(workflow_id: @workflow.id)

      usage = css_select("#workflow-usage tbody tr").first.css("td").map { it.text.strip }
      assert_equal "—", usage[2]
    end

    test "the all-time view leaves pending runs out of the rates" do
      rolled_up_day(400.days.ago.to_date, outcome: "resolved", count: 2)
      rolled_up_day(400.days.ago.to_date, outcome: ScenarioRollup::PENDING, count: 2)
      sign_in @admin

      get admin_analytics_path(range: "all")

      cells = css_select(".stat-cell").index_by { it.at_css(".stat-cell__label").text.strip }
      assert_equal "100.0%", cells["Completion Rate"].at_css(".stat-cell__value").text.strip
      assert_match "of 2 finished calls", cells["Completion Rate"].text
    end

    test "admin can access analytics page" do
      sign_in @admin
      get admin_analytics_path

      assert_response :success
      assert_select "h1", text: /Analytics/
    end

    test "editor cannot access analytics page" do
      sign_in @editor
      get admin_analytics_path

      assert_redirected_to root_path
    end

    test "regular user cannot access analytics page" do
      sign_in @regular_user
      get admin_analytics_path

      assert_redirected_to root_path
    end

    test "analytics page shows stat cards" do
      sign_in @admin
      get admin_analytics_path

      assert_select ".stat-cell", minimum: 4
    end

    test "analytics page filters by date range" do
      Scenario.create!(
        workflow: @workflow,
        user: @admin,
        inputs: {},
        purpose: "simulation",
        started_at: 5.days.ago,
        outcome: "completed",
        completed_at: 5.days.ago + 30.seconds,
        duration_seconds: 30
      )

      sign_in @admin
      get admin_analytics_path, params: { range: "7d" }

      assert_response :success
    end

    test "analytics page filters by workflow" do
      sign_in @admin
      get admin_analytics_path, params: { workflow_id: @workflow.id }

      assert_response :success
    end

    test "analytics page CSV export" do
      Scenario.create!(
        workflow: @workflow,
        user: @admin,
        inputs: {},
        purpose: "simulation",
        started_at: 1.day.ago,
        outcome: "completed",
        completed_at: 1.day.ago + 30.seconds,
        duration_seconds: 30
      )

      sign_in @admin
      get admin_analytics_path(format: :csv)

      assert_response :success
      assert_equal "text/csv", response.content_type.split(";").first
    end
  end
end
