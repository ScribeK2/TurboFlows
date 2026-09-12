require "test_helper"

module Analytics
  # Last Run and Last Active read MAX(started_at) through a select alias, which
  # SQLite hands back as a String; time_ago_in_words then read that String in the
  # server's own zone, so at UTC-4 a run started minutes ago read "about 4 hours
  # ago". PostgreSQL types the value, but a rollup only knows the day, and a day
  # read as a time is hours since midnight, so All time was wrong everywhere.
  #
  # On a UTC machine the old code read correctly, so these tests pin the process
  # to UTC-4. It is a POSIX string, which needs no tzdata to take effect.
  class AnalyticsLastSeenTest < ActionDispatch::IntegrationTest
    setup do
      @zone = ENV.fetch("TZ", nil)
      ENV["TZ"] = "<-04>4"
      @admin = User.create!(
        email: "admin-last-seen-#{SecureRandom.hex(4)}@example.com",
        password: "password123!", password_confirmation: "password123!", role: "admin"
      )
      @workflow = Workflow.create!(title: "Last Seen #{SecureRandom.hex(3)}", user: @admin)
      sign_in @admin
    end

    teardown do
      ENV["TZ"] = @zone
    end

    def cell(table, label)
      row = css_select("##{table} tbody tr").find { it.text.include?(label) }
      assert row, "expected a row for #{label} in ##{table}"
      row.css("td").last.text.strip
    end

    def rolled_up_day(workflow, day)
      ScenarioRollup.create!(
        workflow: workflow, day: day, purpose: "live", outcome: "resolved",
        runs_count: 1, duration_sum_seconds: 60, duration_count: 1,
        calls_count: 1, call_duration_sum_seconds: 60, call_duration_count: 1
      )
    end

    test "a run started minutes ago reads minutes on the Workflows and Agents tabs" do
      assert_equal(-4 * 3600, Time.now.getlocal.utc_offset, "the test only means something off UTC")
      started = 5.minutes.ago.change(usec: 0)
      Scenario.create!(workflow: @workflow, user: @admin, purpose: "live", status: "completed",
                       outcome: "resolved", started_at: started, completed_at: started + 1.minute,
                       execution_path: [], results: {}, inputs: {})

      get analytics_path

      assert_response :success
      assert_equal "5 minutes ago", cell("workflow-usage", @workflow.title)
      assert_equal "5 minutes ago", cell("agent-performance", @admin.email)
    end

    test "all time says which day a workflow last ran, not hours since midnight" do
      earlier = Workflow.create!(title: "Last Seen Earlier #{SecureRandom.hex(3)}", user: @admin)
      rolled_up_day(@workflow, Date.current)
      rolled_up_day(earlier, Date.current - 3)

      get analytics_path(range: "all")

      assert_response :success
      assert_equal "Today", cell("workflow-usage", @workflow.title)
      assert_equal "3 days ago", cell("workflow-usage", earlier.title)
    end
  end
end
