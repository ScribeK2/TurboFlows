require "test_helper"

module Analytics
  # One agent's calls (spec 2026-09-12): a manager opens a CSR on their team from
  # the Agents tab and sees each call once, however many workflows it crossed.
  class AgentCallsTest < ActionDispatch::IntegrationTest
    setup do
      @tag = SecureRandom.hex(3)
      @team = Group.create!(name: "Calls Team #{@tag}")
      @sibling = Group.create!(name: "Calls Sibling #{@tag}")
      @manager = person("manager")
      GroupManager.create!(group: @team, user: @manager)
      @csr = person("csr", group: @team)
      @outsider = person("outsider", group: @sibling)
      @start = Workflow.create!(title: "Calls Start #{@tag}", user: @manager)
      @next = Workflow.create!(title: "Calls Next #{@tag}", user: @manager)
      sign_in @manager
    end

    def person(label, group: nil)
      user = User.create!(email: "calls-#{label}-#{@tag}@example.com", password: "password123!",
                          password_confirmation: "password123!", role: "user")
      UserGroup.create!(user:, group:) if group
      user
    end

    def run_scenario(workflow:, user:, started:, outcome: "resolved", handed_off_from: nil, purpose: "live")
      Scenario.create!(workflow:, user:, purpose:, status: "completed", outcome:, handed_off_from:,
                       started_at: started, completed_at: started + 2.minutes,
                       execution_path: [], results: {}, inputs: {})
    end

    def rows
      css_select(".list-row")
    end

    test "a handed-off call is one row, newest first, naming where it started and ended" do
      older = run_scenario(workflow: @start, user: @csr, started: 3.days.ago)
      origin = run_scenario(workflow: @start, user: @csr, started: 1.day.ago.change(usec: 0), outcome: "transferred")
      run_scenario(workflow: @next, user: @csr, started: origin.started_at + 1.minute, handed_off_from: origin)

      get analytics_agent_path(@csr)

      assert_response :success
      assert_equal 2, rows.size
      assert_select rows.first, "a[href=?]", analytics_run_path(origin), text: @start.title
      assert_match "→ #{@next.title}", rows.first.text
      assert_match "Resolved", rows.first.text
      assert_match "3m 0s", rows.first.text
      assert_select rows.last, "a[href=?]", analytics_run_path(older)
    end

    test "an agent outside the team and an id that does not exist are turned away alike" do
      run_scenario(workflow: @start, user: @outsider, started: 1.day.ago)

      get analytics_agent_path(@outsider)
      outside = [response.status, response.location, flash[:alert]]

      get analytics_agent_path(User.maximum(:id) + 1)

      assert_equal outside, [response.status, response.location, flash[:alert]]
      assert_redirected_to root_path
    end

    test "the Agents tab links each agent to their calls, keeping the range" do
      run_scenario(workflow: @start, user: @csr, started: 1.day.ago)

      get analytics_path(range: "7d")

      assert_select "#agent-performance a[href=?]", analytics_agent_path(@csr, range: "7d")
    end

    test "the range carries over: 30 days by default, 90 when asked" do
      run_scenario(workflow: @start, user: @csr, started: 45.days.ago)

      get analytics_agent_path(@csr)
      assert_equal 0, rows.size

      get analytics_agent_path(@csr, range: "90d")
      assert_equal 1, rows.size
    end

    test "the purpose filter narrows the calls to live or simulated ones" do
      live = run_scenario(workflow: @start, user: @csr, started: 2.hours.ago)
      simulated = run_scenario(workflow: @start, user: @csr, started: 1.hour.ago, purpose: "simulation")

      get analytics_agent_path(@csr, purpose: "simulation")
      assert_equal 1, rows.size
      assert_select rows.first, "a[href=?]", analytics_run_path(simulated)

      get analytics_agent_path(@csr, purpose: "live")
      assert_equal 1, rows.size
      assert_select rows.first, "a[href=?]", analytics_run_path(live)

      get analytics_agent_path(@csr)
      assert_equal 2, rows.size
    end

    test "calls come 25 to a page" do
      26.times { |i| run_scenario(workflow: @start, user: @csr, started: (i + 1).hours.ago) }

      get analytics_agent_path(@csr, page: 2)

      assert_equal 1, rows.size
      assert_select "nav.pagination a[aria-current=page]", text: "2"
    end
  end
end
