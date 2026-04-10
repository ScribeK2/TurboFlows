require "test_helper"

class Admin::DataHealthControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(
      email: "admin-health-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    @regular = User.create!(
      email: "user-health-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
  end

  test "admin can access data health page" do
    sign_in @admin
    get admin_data_health_path

    assert_response :success
    assert_select "h1", /Data Health/
  end

  test "non-admin is redirected from data health page" do
    sign_in @regular
    get admin_data_health_path

    assert_redirected_to root_path
  end

  test "unauthenticated user is redirected from data health page" do
    get admin_data_health_path

    assert_response :redirect
  end

  test "data health page displays table names" do
    sign_in @admin
    get admin_data_health_path

    assert_response :success
    assert_select "td", /scenarios/
    assert_select "td", /step_responses/
  end

  test "data health page displays retention configuration" do
    sign_in @admin
    get admin_data_health_path

    assert_response :success
    assert_match(/\d+ days/, response.body)
  end
end
