require "test_helper"

class Admin::AnalyticsControllerTest < ActionDispatch::IntegrationTest
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
    @workflow = Workflow.create!(
      title: "Analytics Test Workflow",
      user: @admin,
      steps: [
        { "id" => "s1", "type" => "question", "title" => "Q1", "question" => "Test?" }
      ]
    )
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

    assert_select ".solid-card", minimum: 4
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
