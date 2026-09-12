require "csv"
require "test_helper"

module Analytics
  # A manager's Analytics is their team's (spec 2026-09-12): every tab, stat,
  # filter list and CSV row. The filter lists were built from every run with no
  # scope, which is the easiest leak to miss, so they are asserted on directly.
  class ManagerAnalyticsTest < ActionDispatch::IntegrationTest
    setup do
      @tag = SecureRandom.hex(3)
      department = Group.create!(name: "Mgr Dept #{@tag}")
      @team = Group.create!(name: "Mgr Team #{@tag}", parent: department)
      sibling = Group.create!(name: "Mgr Sibling #{@tag}", parent: department)
      @admin = person("admin", role: "admin")
      @manager = person("manager")
      GroupManager.create!(group: @team, user: @manager)
      @csr = person("csr", group: @team)
      @outsider = person("outsider", group: sibling)
      @team_flow = Workflow.create!(title: "Mgr Team Flow #{@tag}", user: @admin)
      @sibling_flow = Workflow.create!(title: "Mgr Sibling Flow #{@tag}", user: @admin)
      run_scenario(@team_flow, @csr)
      run_scenario(@sibling_flow, @outsider)
    end

    def person(label, role: "user", group: nil)
      user = User.create!(email: "mgr-#{label}-#{@tag}@example.com", password: "password123!",
                          password_confirmation: "password123!", role:)
      UserGroup.create!(user:, group:) if group
      user
    end

    def run_scenario(workflow, user)
      Scenario.create!(workflow:, user:, purpose: "live", status: "completed", outcome: "resolved",
                       started_at: 1.day.ago, completed_at: 1.day.ago + 2.minutes,
                       execution_path: [], results: {}, inputs: {})
    end

    def stat_value(label)
      css_select(".stat-cell").index_by { it.at_css(".stat-cell__label").text.strip }
                              .fetch(label).at_css(".stat-cell__value").text.strip
    end

    test "a manager's page counts only their team, and its filter lists name nobody else" do
      sign_in @manager

      get analytics_path

      assert_response :success
      assert_select ".page-header-section__subtitle", text: /Runs by members of #{@team.name} and its teams/
      assert_equal "1", stat_value("Total Calls")
      assert_select "select[name=user_id] option", text: @csr.email
      assert_select "select[name=user_id] option", text: @outsider.email, count: 0
      assert_select "select[name=workflow_id] option", text: @team_flow.title
      assert_select "select[name=workflow_id] option", text: @sibling_flow.title, count: 0
      assert_select "#workflow-usage a", text: @sibling_flow.title, count: 0
      assert_no_match(/#{Regexp.escape(@outsider.email)}/, response.body)
    end

    test "a manager gets no All time and no Group filter, and All time reads as 30 days" do
      sign_in @manager

      get analytics_path(range: "all")

      assert_response :success
      # Scoped to the Date Range group: the Purpose filter has its own "All"
      # button (data-value="all"), unrelated to the All-time range.
      assert_select "[aria-label='Date range'] button[data-value=all]", 0
      assert_select "button.is-active[data-value='30d']"
      assert_select "select[name=group_id]", 0
      assert_match(/Individual runs/, response.body)
    end

    test "a manager's CSV holds only their team's runs" do
      sign_in @manager

      get analytics_path(format: :csv)

      emails = CSV.parse(response.body, headers: true).pluck("User")
      assert_equal [@csr.email], emails
    end

    test "an administrator still sees everyone, with All time and the Group filter" do
      sign_in @admin

      get analytics_path

      assert_response :success
      assert_equal "2", stat_value("Total Calls")
      assert_select "select[name=user_id] option", text: @outsider.email
      assert_select "button[data-value=all]"
      assert_select "select[name=group_id]"
      assert_select ".page-header-section__subtitle", text: /Workflow usage/
    end
  end
end
