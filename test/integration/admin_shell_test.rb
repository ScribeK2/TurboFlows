require "test_helper"

class AdminShellTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "shell-admin-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                          password_confirmation: "password123!", role: "admin")
    sign_in @admin
  end

  test "every admin page carries the sidebar with its own section current" do
    group = Group.create!(name: "Shell Group #{SecureRandom.hex(3)}")
    {
      admin_root_path => "Overview",
      admin_users_path => "Users",
      admin_user_path(@admin) => "Users",
      admin_groups_path => "Groups",
      admin_group_path(group) => "Groups",
      admin_group_memberships_path(group, q: "shell") => "Groups",
      admin_data_health_path => "Data Health",
      admin_smtp_setting_path => "Email"
    }.each do |path, current|
      get path
      assert_response :success, path
      assert_select "nav.admin-nav a.admin-nav__link", 5
      assert_select "nav.admin-nav a[aria-current=page]", count: 1, text: /#{current}/
    end
  end

  test "sections are ordered by use, with the divider before the check-when-wrong pages" do
    get admin_users_path

    items = css_select("nav.admin-nav li").map do |li|
      li["class"].to_s.include?("admin-nav__divider") ? "|" : li.css(".admin-nav__label").text.strip
    end
    assert_equal ["Overview", "Users", "Groups", "|", "Data Health", "Email"], items
  end

  test "pages outside admin keep the plain layout" do
    get workflows_path

    assert_response :success
    assert_select ".admin-shell", 0
    assert_select "main.page-main"
  end

  # Admins manage workflows at /workflows, which already shows them every
  # workflow with delete. The admin copy added only a read-only step list.
  test "admin Workflows is gone" do
    get "/admin/workflows"

    assert_response :not_found
  end
end
