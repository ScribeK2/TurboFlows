require "test_helper"

class NavControllerTest < ActionDispatch::IntegrationTest
  fixtures :users, :workflows

  def setup
    @admin = users(:admin_user)
    @editor = users(:editor_user)
    @regular = users(:regular_user)
  end

  # --- menu action ---

  test "menu requires authentication" do
    get nav_menu_path
    assert_redirected_to new_user_session_path
  end

  test "menu renders turbo frame for admin" do
    sign_in @admin
    get nav_menu_path
    assert_response :success
    assert_select "turbo-frame#nav_menu"
  end

  test "admin menu includes admin section" do
    sign_in @admin
    get nav_menu_path
    assert_response :success
    assert_select "a[href='#{admin_users_path}']"
    assert_select "a[href='#{admin_workflows_path}']"
    assert_select "a[href='#{admin_groups_path}']"
    assert_select "a[href='#{admin_analytics_path}']"
  end

  test "admin menu includes actions section" do
    sign_in @admin
    get nav_menu_path
    assert_select "a[href='#{new_workflow_path}']"
  end

  test "editor menu includes actions but not admin" do
    sign_in @editor
    get nav_menu_path
    assert_response :success
    assert_select "a[href='#{new_workflow_path}']"
    assert_select "a[href='#{admin_users_path}']", count: 0
  end

  test "regular user menu has navigation only" do
    sign_in @regular
    get nav_menu_path
    assert_response :success
    assert_select "a[href='#{root_path}']"
    assert_select "a[href='#{workflows_path}']"
    assert_select "a[href='#{new_workflow_path}']", count: 0
    assert_select "a[href='#{admin_users_path}']", count: 0
  end

  # --- search_data action ---

  test "search_data requires authentication" do
    get nav_search_data_path(format: :json)
    assert_response :unauthorized
  end

  test "search_data returns JSON array of workflows" do
    sign_in @admin
    Workflow.create!(title: "Test Flow", user: @admin, status: "draft")
    Workflow.create!(title: "Draft Flow", user: @admin, status: "draft")

    get nav_search_data_path(format: :json)
    assert_response :success

    data = response.parsed_body
    assert_kind_of Array, data
    assert_operator data.length, :>=, 2, "Expected at least 2 workflows"

    first = data.first
    assert first.key?("id")
    assert first.key?("title")
    assert first.key?("description")
    assert first.key?("status")
    assert first.key?("path")
  end

  test "search_data scopes workflows to user access" do
    other_user = users(:one)
    Workflow.create!(title: "Public Flow", user: other_user, status: "published", is_public: true)
    Workflow.create!(title: "Private Flow", user: other_user, status: "draft", is_public: false)
    Workflow.create!(title: "My Flow", user: @regular, status: "draft")

    sign_in @regular
    get nav_search_data_path(format: :json)

    data = response.parsed_body
    titles = data.pluck("title")
    assert_includes titles, "Public Flow"
    assert_includes titles, "My Flow"
    assert_not_includes titles, "Private Flow"
  end
end
