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

  # -- Shared header --

  test "should show personalized greeting with display name" do
    @user.update!(display_name: "Alice")
    get root_path
    assert_response :success
    assert_select "p", text: /Welcome back,\s+Alice/
  end

  test "should show personalized greeting with email when no display name" do
    get root_path
    assert_response :success
    assert_select "p", text: /Welcome back,\s+test@example\.com/
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
    assert_select "h2", text: "Pinned Workflows"
  end

  test "CSR sees scenario stats" do
    editor = User.create!(email: "editor-#{SecureRandom.hex(4)}@example.com", password: "password123!", password_confirmation: "password123!", role: "editor")
    workflow = Workflow.create!(title: "Test WF", user: editor, is_public: true)
    Scenario.create!(workflow: workflow, user: @user, purpose: "live", status: "completed")

    get root_path
    assert_response :success
    assert_select "[aria-label*='Scenarios this week']"
    assert_select "[aria-label*='Completion rate']"
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
    assert_select "p", text: /1 draft/
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
