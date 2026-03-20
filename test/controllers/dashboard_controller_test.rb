require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  def setup
    # Create user directly instead of using fixtures
    @user = User.create!(
      email: "test@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    sign_in @user
  end

  test "should get index" do
    get root_path

    assert_response :success
  end

  test "should show user's workflows" do
    Workflow.create!(
      title: "Workflow 1",
      user: @user
    )
    Workflow.create!(
      title: "Workflow 2",
      user: @user
    )

    get root_path

    assert_response :success
    assert_select "h2", text: /Recent Workflows/
  end

  test "should require authentication" do
    sign_out @user
    get root_path

    assert_redirected_to new_user_session_path
  end

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

  test "should show scenario stats" do
    workflow = Workflow.create!(title: "Test Workflow", user: @user)
    Scenario.create!(workflow: workflow, user: @user, status: "completed")
    Scenario.create!(workflow: workflow, user: @user, status: "active")

    get root_path

    assert_response :success
    # Check that scenario stat cards are present with correct ARIA labels
    assert_select "[aria-label=?]", "Scenarios run: 2"
    assert_select "[aria-label=?]", "Scenario completion rate: 50%"
  end

  test "should show draft count for editors" do
    @user.update!(role: "editor")
    Workflow.create!(title: "Published WF", user: @user, status: "published")
    Workflow.create!(title: "Draft WF", user: @user, status: "draft")

    get root_path

    assert_response :success
    # Draft sub-line should be visible
    assert_select "p", text: /1 draft/
  end

  test "should not show draft count for regular users" do
    get root_path

    assert_response :success
    assert_select "p", text: /draft/, count: 0
  end

  test "should show quick actions for editors" do
    @user.update!(role: "editor")

    get root_path

    assert_response :success
    assert_select "a[aria-label='Create a new workflow']"
    assert_select "a[aria-label='Browse workflow templates']"
  end

  test "should not show quick actions for regular users" do
    get root_path

    assert_response :success
    assert_select "a[aria-label='Create a new workflow']", count: 0
  end
end
