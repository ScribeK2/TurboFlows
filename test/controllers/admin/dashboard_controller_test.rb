require "test_helper"

class Admin::DashboardControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(
      email: "admin-dash-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    @editor = User.create!(
      email: "editor-dash-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @user = User.create!(
      email: "user-dash-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
  end

  test "admin should be able to access admin dashboard" do
    sign_in @admin
    get admin_root_path

    assert_response :success
  end

  test "editor should not be able to access admin dashboard" do
    sign_in @editor
    get admin_root_path

    assert_redirected_to root_path
    assert_equal "You don't have permission to access this page.", flash[:alert]
  end

  test "user should not be able to access admin dashboard" do
    sign_in @user
    get admin_root_path

    assert_redirected_to root_path
    assert_equal "You don't have permission to access this page.", flash[:alert]
  end

  test "admin dashboard should show system stats" do
    sign_in @admin
    get admin_root_path

    assert_response :success
    assert_select "h1", text: /Admin Dashboard/
  end
end
