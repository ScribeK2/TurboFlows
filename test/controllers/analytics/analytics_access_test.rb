require "test_helper"

module Analytics
  # Analytics left the admin area for its own address (spec 2026-09-12), so the
  # managers of groups can use it without becoming administrators. Everyone
  # else sees no link to it and cannot open it.
  class AnalyticsAccessTest < ActionDispatch::IntegrationTest
    setup do
      @tag = SecureRandom.hex(3)
      @team = Group.create!(name: "Access Team #{@tag}")
      @admin = person("admin", "admin")
      @manager = person("manager", "user")
      GroupManager.create!(group: @team, user: @manager)
      @editor = person("editor", "editor")
      @regular = person("regular", "user")
      UserGroup.create!(user: @regular, group: @team)
    end

    def person(label, role)
      User.create!(email: "access-#{label}-#{@tag}@example.com", password: "password123!",
                   password_confirmation: "password123!", role:)
    end

    test "administrators and managers open Analytics and see it current in the top bar" do
      [@admin, @manager].each do |user|
        sign_in user

        get analytics_path

        assert_response :success, user.email
        assert_select "a.nav__link[href=?][aria-current=page]", analytics_path, text: "Analytics"
        assert_select ".admin-shell", 0
        sign_out :user
      end
    end

    test "Editors and Regular users without the grant see no link and are turned away" do
      [@editor, @regular].each do |user|
        sign_in user

        get play_path
        assert_select "a.nav__link", text: "Analytics", count: 0

        get analytics_path
        assert_redirected_to root_path, user.email
        assert_equal "You don't have permission to access this page.", flash[:alert]
        sign_out :user
      end
    end

    test "signed-out visitors are sent to sign in" do
      get analytics_path

      assert_redirected_to new_user_session_path
    end

    test "the old admin address redirects permanently, keeping its filters" do
      sign_in @admin

      get "/admin/analytics?range=7d&tab=2"

      assert_response :moved_permanently
      assert_redirected_to "/analytics?range=7d&tab=2"
    end

    test "an old CSV export link still leads to the CSV, not the page" do
      sign_in @admin

      get "/admin/analytics.csv?range=7d"

      assert_response :moved_permanently
      assert_redirected_to "/analytics.csv?range=7d"
    end
  end
end
