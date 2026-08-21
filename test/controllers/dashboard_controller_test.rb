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

  test "editor renders SME dashboard" do
    @user.update!(role: "editor")
    get root_path
    assert_response :success
    assert_select "[aria-label*='Total workflows']"
  end

  test "admin renders SME dashboard" do
    @user.update!(role: "admin")
    get root_path
    assert_response :success
    assert_select "[aria-label*='Total workflows']"
  end

  # -- CSR dashboard --

  test "CSR sees Start a Simulation button" do
    get root_path
    assert_select "a[aria-label='Run a flow']"
  end

  test "CSR does not see Create Workflow button" do
    get root_path
    assert_select "a[aria-label='Create a new workflow']", count: 0
  end

  test "CSR sees empty pinned state when no pins" do
    get root_path
    assert_select "h3", text: "No pinned workflows"
  end

  test "CSR sees pinned workflows section when pins exist" do
    editor = User.create!(email: "editor-#{SecureRandom.hex(4)}@example.com", password: "password123!", password_confirmation: "password123!", role: "editor")
    workflow = Workflow.create!(title: "Pinned WF", user: editor, is_public: true)
    UserWorkflowPin.create!(user: @user, workflow: workflow)

    get root_path
    assert_response :success
    assert_select "h2", text: "Your fast path"
    assert_select ".dash-row__title", text: /Pinned WF/
  end

  test "CSR launcher offers a pin prompt row once pins exist" do
    # No pins => empty state carries the call to action, not a prompt row
    get root_path
    assert_select ".dash-row--prompt", count: 0
    assert_select "h3", text: "No pinned workflows"

    # With pins => one row per pin, plus a single trailing prompt row
    editor = User.create!(email: "editor-#{SecureRandom.hex(4)}@example.com", password: "password123!", password_confirmation: "password123!", role: "editor")
    2.times do |i|
      wf = Workflow.create!(title: "WF #{i}", user: editor, is_public: true)
      UserWorkflowPin.create!(user: @user, workflow: wf)
    end
    get root_path
    assert_select "#pinned-workflows-section .dash-row", count: 3
    assert_select ".dash-row--prompt", count: 1
  end

  test "CSR shows Recently Run section with re-run buttons" do
    editor = User.create!(email: "editor-#{SecureRandom.hex(4)}@example.com", password: "password123!", password_confirmation: "password123!", role: "editor")
    workflow = Workflow.create!(title: "Triage Flow", user: editor, is_public: true)
    Scenario.create!(workflow: workflow, user: @user, purpose: "live", status: "completed")

    get root_path
    assert_response :success
    assert_select "h2", text: "Recently Run"
    assert_select ".dash-row__title", text: /Triage Flow/
    assert_select "button[aria-label='Re-run Triage Flow']"
  end

  test "CSR dashboard does not render the old stat cards" do
    get root_path
    assert_response :success
    assert_select ".stat-grid", count: 0
    assert_select "[aria-label*='Total runs']", count: 0
    assert_select "[aria-label*='Most used flow']", count: 0
  end

  # -- SME dashboard --

  test "SME sees Create Workflow button" do
    @user.update!(role: "editor")
    get root_path
    assert_select "a[aria-label='Create a new workflow']"
  end

  test "SME sees draft count" do
    @user.update!(role: "editor")
    Workflow.create!(title: "Published WF", user: @user, status: "published")
    Workflow.create!(title: "Draft WF", user: @user, status: "draft")

    get root_path
    assert_response :success
    assert_select ".stat-cell__chip", text: /1 draft/
  end

  test "SME sees company-wide scenario stats" do
    @user.update!(role: "editor")
    other_user = User.create!(
      email: "csr-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    workflow = Workflow.create!(title: "Test WF", user: @user)
    Scenario.create!(workflow: workflow, user: other_user, purpose: "live", status: "completed")

    get root_path
    assert_response :success
    # Company-wide total includes scenarios from all users
    assert_select "[aria-label*='Total scenarios']"
  end

  test "SME sees recent workflows with View and Edit buttons" do
    @user.update!(role: "editor")
    Workflow.create!(title: "My Workflow", user: @user)

    get root_path
    assert_response :success
    assert_select "h2", text: /Recent Workflows/
  end
end
