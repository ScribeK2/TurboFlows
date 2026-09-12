require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(
      email: "test@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    sign_in @user
  end

  # -- Authentication --

  test "should require authentication" do
    sign_out @user
    get root_path
    assert_redirected_to new_user_session_path
  end

  # -- Role-based rendering --

  test "regular user renders CSR dashboard" do
    get root_path
    assert_response :success
    # CSR view shows either pinned section or empty pinned state
    assert_select "h3", text: "No pinned workflows"
  end

  # -- CSR dashboard --

  test "CSR sees Start a Simulation button" do
    get root_path
    assert_select "a[aria-label='Run a flow']"
  end

  test "CSR does not see Create Workflow button" do
    get root_path
    assert_select "[aria-label='Create a new workflow']", count: 0
  end

  test "CSR sees empty pinned state when no pins" do
    get root_path
    assert_select "h3", text: "No pinned workflows"
  end

  test "CSR sees pinned workflows section when pins exist" do
    editor = User.create!(email: "editor-#{SecureRandom.hex(4)}@example.com", password: "password123!", password_confirmation: "password123!", role: "editor")
    workflow = file_in_global(Workflow.create!(title: "Pinned WF", user: editor))
    UserWorkflowPin.create!(user: @user, workflow: workflow)

    get root_path
    assert_response :success
    assert_select "h2", text: "Your fast path"
    assert_select ".list-row__title", text: /Pinned WF/
  end

  test "CSR launcher offers a pin prompt row once pins exist" do
    # No pins => empty state carries the call to action, not a prompt row
    get root_path
    assert_select ".list-row--prompt", count: 0
    assert_select "h3", text: "No pinned workflows"

    # With pins => one row per pin, plus a single trailing prompt row
    editor = User.create!(email: "editor-#{SecureRandom.hex(4)}@example.com", password: "password123!", password_confirmation: "password123!", role: "editor")
    2.times do |i|
      wf = file_in_global(Workflow.create!(title: "WF #{i}", user: editor))
      UserWorkflowPin.create!(user: @user, workflow: wf)
    end
    get root_path
    assert_select "#pinned-workflows-section .list-row", count: 3
    assert_select ".list-row--prompt", count: 1
  end

  test "CSR shows Recently Run section with re-run buttons" do
    editor = User.create!(email: "editor-#{SecureRandom.hex(4)}@example.com", password: "password123!", password_confirmation: "password123!", role: "editor")
    workflow = file_in_global(Workflow.create!(title: "Triage Flow", user: editor))
    Scenario.create!(workflow: workflow, user: @user, purpose: "live", status: "completed")

    get root_path
    assert_response :success
    assert_select "h2", text: "Recently Run"
    assert_select ".list-row__title", text: /Triage Flow/
    assert_select "button[aria-label='Re-run Triage Flow']"
  end

  test "CSR dashboard does not render the old stat cards" do
    get root_path
    assert_response :success
    assert_select ".stat-panel", count: 0
    assert_select "[aria-label*='Total runs']", count: 0
    assert_select "[aria-label*='Most used flow']", count: 0
  end

  # -- Editor and Admin home (spec docs/designs/2026-09-12-editor-admin-home.md) --

  test "an editor gets the home page, not the old stats" do
    @user.update!(role: "editor")

    get root_path

    assert_response :success
    assert_select ".dashboard-greet"
    assert_select ".stat-panel", count: 0
    assert_select ".dashboard-greet__attention", count: 0
  end

  test "an editor's last workflow is the hero, and Continue editing is the one filled button" do
    @user.update!(role: "editor")
    workflow = workflow_with_step("My Draft")

    get root_path

    assert_select ".home-resume__title", text: /My Draft/
    assert_select ".home-resume a.btn--primary[href=?]", workflow_path(workflow, edit: true), text: "Continue editing"
    assert_select "button.btn--secondary[aria-label='Create a new workflow']"
    assert_select ".dashboard-layout .btn--primary", count: 1
  end

  test "an editor with nothing yet gets a filled Create Workflow and one line about what will appear" do
    @user.update!(role: "editor")

    get root_path

    assert_select ".home-resume", count: 0
    assert_select "button.btn--primary[aria-label='Create a new workflow']", count: 1
    assert_select ".dashboard-layout p", text: /Workflows you create will appear here/
    assert_select "#home-waiting", count: 0
    assert_select "#home-also-recent", count: 0
  end

  test "a draft hero says what blocks its publish and links to the health panel" do
    @user.update!(role: "editor")
    workflow = workflow_with_step("Unpublishable")

    get root_path

    assert_select ".home-resume__blockers a[href=?]", workflow_path(workflow, edit: true, health: true),
                  text: /1 thing to fix before publishing/
  end

  test "a published hero shows no blockers line" do
    @user.update!(role: "editor")
    file_in_global(workflow_with_step("Live", status: "published"))

    get root_path

    assert_select ".home-resume"
    assert_select ".home-resume__blockers", count: 0
  end

  test "waiting on you names five drafts and links the rest to your own drafts" do
    @user.update!(role: "editor")
    7.times { |i| workflow_with_step("Draft #{i}", edited_at: i.hours.ago) }

    get root_path

    assert_select "#home-waiting-drafts .list-row__title", text: "7 drafts not yet published"
    assert_select "#home-waiting-drafts li a", count: 6
    assert_select "#home-waiting-drafts a[href=?]", workflows_path(owner: "me", status: "draft"), text: "+2 more"
  end

  test "also recent lists your other workflows and links to all of yours" do
    @user.update!(role: "editor")
    workflow_with_step("Newest", edited_at: 1.hour.ago)
    workflow_with_step("Older", edited_at: 1.day.ago)

    get root_path

    assert_select "#home-also-recent .list-row__title", text: /Older/
    assert_select "#home-also-recent .list-row__title", text: /Newest/, count: 0
    assert_select "#home-also-recent a[href=?]", workflows_path(owner: "me"), text: "View all"
  end

  test "an editor's published workflows with no audience are named" do
    @user.update!(role: "editor")
    workflow_with_step("Hidden live", status: "published")

    get root_path

    assert_select "#home-waiting-no-audience a", text: "Hidden live"
  end

  test "an admin gets the attention strip instead of a no-audience row" do
    @user.update!(role: "admin")
    workflow_with_step("Admin hidden live", status: "published")

    get root_path

    assert_select "#home-waiting-no-audience", count: 0
    assert_select "#home-admin-attention", text: /with no audience/
    assert_select "#home-admin-attention a[href=?]", admin_root_path, text: "Admin Overview"
  end

  test "the admin strip is absent when nothing waits on an administrator" do
    @user.update!(role: "admin")
    # Fixture rows persist: published workflows in no group, and users in no group.
    Workflow.where(id: Workflow.published_without_audience.select(:id)).update_all(status: "draft")
    User.where(id: User.awaiting_groups.select(:id)).update_all(deactivated_at: Time.current)

    get root_path

    assert_select "#home-admin-attention", count: 0
  end

  test "an admin who has built nothing sees the library's last edit, with its owner" do
    @user.update!(role: "admin")
    editor = User.create!(email: "home-editor-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                          password_confirmation: "password123!", role: "editor")
    workflow_with_step("Editor's work", user: editor, edited_at: 1.minute.from_now)

    get root_path

    assert_select ".home-resume__eyebrow", text: "Last edited in the library"
    assert_select ".home-resume__title", text: /Editor's work/
    assert_select ".home-resume__meta", text: /#{Regexp.escape(editor.display_label)}/
  end

  test "the home page skips Turbo's cached preview" do
    @user.update!(role: "editor")

    get root_path

    assert_select "meta[name='turbo-cache-control'][content='no-preview']"
  end

  test "home page queries do not grow with the workflows you own" do
    @user.update!(role: "editor")
    file_in_global(workflow_with_step("Live 0", status: "published"))
    get root_path

    small = count_queries { get root_path }
    9.times { |i| file_in_global(workflow_with_step("Live #{i + 1}", status: "published", edited_at: 1.day.ago)) }
    large = count_queries { get root_path }

    assert_equal small, large, "something on home is queried per workflow"
  end

  private

  def workflow_with_step(title, user: @user, status: "draft", edited_at: Time.current)
    workflow = Workflow.create!(title:, user:, status:)
    step = Steps::Resolve.create!(workflow:, position: 0, title: "Done", resolution_type: "success")
    step.update_columns(updated_at: edited_at)
    workflow.update_columns(updated_at: edited_at)
    workflow
  end
end
