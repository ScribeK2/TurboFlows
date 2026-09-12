require "test_helper"

module Analytics
  # One call, read-only (spec 2026-09-12): the steps a CSR took and what they
  # answered, for their manager, with nothing that acts on the run.
  class RunViewTest < ActionDispatch::IntegrationTest
    setup do
      @tag = SecureRandom.hex(3)
      @team = Group.create!(name: "Run View Team #{@tag}")
      @manager = person("manager")
      GroupManager.create!(group: @team, user: @manager)
      @csr = person("csr", group: @team)
      @admin = person("admin", role: "admin")
      # In no group, so the Regular manager cannot open either workflow.
      @start = Workflow.create!(title: "Run View Start #{@tag}", user: @admin)
      @next = Workflow.create!(title: "Run View Next #{@tag}", user: @admin)

      t0 = 1.day.ago.change(usec: 0)
      @origin = Scenario.create!(
        workflow: @start, user: @csr, purpose: "live", status: "completed", outcome: "transferred",
        started_at: t0, completed_at: t0 + 1.minute, results: {}, inputs: {},
        execution_path: [{ "step_type" => "question", "step_title" => "Is this about an account?", "answer" => "yes" }]
      )
      @handed_to = Scenario.create!(
        workflow: @next, user: @csr, purpose: "live", status: "completed", outcome: "resolved",
        handed_off_from: @origin, started_at: t0 + 1.minute, completed_at: t0 + 4.minutes, results: {}, inputs: {},
        execution_path: [{ "step_type" => "resolve", "step_title" => "Transferred to ext 256", "resolved" => true }]
      )
      # How the runner records a handoff: a sub_flow entry naming the handed-to run.
      @origin.update!(execution_path: @origin.execution_path + [
        { "step_type" => "sub_flow", "step_title" => "Continue in #{@next.title}", "subflow_started" => true,
          "child_scenario_id" => @handed_to.id, "handed_off" => true }
      ])
    end

    def person(label, role: "user", group: nil)
      user = User.create!(email: "runview-#{label}-#{@tag}@example.com", password: "password123!",
                          password_confirmation: "password123!", role:)
      UserGroup.create!(user:, group:) if group
      user
    end

    test "a manager reads every step of a CSR's call, across the handoff" do
      sign_in @manager

      get analytics_run_path(@origin)

      assert_response :success
      assert_select ".exec-step h3", text: "Is this about an account?"
      assert_select ".exec-step", text: /Answer:\s*yes/
      assert_select ".exec-step h3", text: "Transferred to ext 256"
      assert_select ".scenario-status-badge", text: /Completed/
      assert_select "a.page-back[href=?]", analytics_agent_path(@csr)
    end

    test "a later part of the call opens the call from its start" do
      sign_in @manager

      get analytics_run_path(@handed_to)

      assert_redirected_to analytics_run_path(@origin)
    end

    test "a run outside the team and an id that does not exist are turned away alike" do
      elsewhere = Scenario.create!(workflow: @start, user: person("outsider"), purpose: "live", status: "completed",
                                   outcome: "resolved", started_at: 1.day.ago, completed_at: 1.day.ago,
                                   execution_path: [], results: {}, inputs: {})
      sign_in @manager

      get analytics_run_path(elsewhere)
      outside = [response.status, response.location, flash[:alert]]

      get analytics_run_path(Scenario.maximum(:id) + 1)

      assert_equal outside, [response.status, response.location, flash[:alert]]
      assert_redirected_to root_path
    end

    test "nothing on the page acts on the run" do
      sign_in @manager

      get analytics_run_path(@origin)

      assert_no_match(/Run Again|Try Again|Edit Workflow|Copy Link/, response.body)
      assert_select "form[action=?]", workflow_execution_path(@start), 0
    end

    test "the workflow is linked only for a viewer who can open it" do
      sign_in @manager
      get analytics_run_path(@origin)
      assert_select ".page-header-section__ident a", 0
      assert_select ".page-header-section__ident", text: @start.title

      sign_out :user
      sign_in @admin
      get analytics_run_path(@origin)
      assert_select ".page-header-section__ident a[href=?]", workflow_path(@start)
    end

    test "filing the workflow in Global still gives a Regular manager no link, only an Admin gets one" do
      file_in_global(@start)
      sign_in @manager

      get analytics_run_path(@origin)

      assert_select ".page-header-section__ident a", 0
      assert_select ".page-header-section__ident", text: @start.title

      sign_out :user
      sign_in @admin
      get analytics_run_path(@origin)
      assert_select ".page-header-section__ident a[href=?]", workflow_path(@start)
    end

    test "an administrator can open an anonymous share-link call" do
      anonymous = Scenario.create!(workflow: @start, user: nil, purpose: "live", status: "completed",
                                   outcome: "resolved", started_at: 1.day.ago, completed_at: 1.day.ago,
                                   execution_path: [], results: {}, inputs: {})
      sign_in @admin

      get analytics_run_path(anonymous)

      assert_response :success
      assert_select "h1", text: /an anonymous visitor/
      assert_select "a.page-back[href=?]", analytics_path
    end
  end
end
