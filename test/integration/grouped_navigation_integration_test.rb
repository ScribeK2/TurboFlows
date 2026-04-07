require "test_helper"

class GroupedNavigationIntegrationTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(
      email: "admin-nav-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    @user = User.create!(
      email: "user-nav-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    @parent_group = Group.create!(name: "Parent Group")
    @child_group = Group.create!(name: "Child Group", parent: @parent_group)
    @workflow1 = Workflow.create!(title: "Workflow in Parent", user: @admin)
    @workflow2 = Workflow.create!(title: "Workflow in Child", user: @admin)

    # Remove Uncategorized assignments
    @workflow1.group_workflows.destroy_all
    @workflow2.group_workflows.destroy_all

    GroupWorkflow.create!(group: @parent_group, workflow: @workflow1, is_primary: true)
    GroupWorkflow.create!(group: @child_group, workflow: @workflow2, is_primary: true)
  end

  test "editor can navigate to workflows by group" do
    editor = User.create!(
      email: "editor-nav-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    UserGroup.create!(group: @parent_group, user: editor)
    # Make workflows public so editor can see them
    @workflow1.update!(is_public: true)
    @workflow2.update!(is_public: true)
    sign_in editor

    get workflows_path, params: { group_id: @parent_group.id }

    assert_response :success
    assert_match "Workflow in Parent", response.body
    assert_match "Workflow in Child", response.body # Should include descendants
  end

  test "editor can see group hierarchy in sidebar" do
    editor = User.create!(
      email: "editor-nav2-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    UserGroup.create!(group: @parent_group, user: editor)
    sign_in editor

    get workflows_path

    assert_response :success
    assert_match "Parent Group", response.body
    assert_match "Child Group", response.body
  end

  test "editor cannot access workflows from unassigned groups" do
    editor = User.create!(
      email: "editor-nav3-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    other_group = Group.create!(name: "Other Group")
    other_workflow = Workflow.create!(title: "Other Workflow", user: @admin, is_public: false)

    other_workflow.group_workflows.destroy_all
    GroupWorkflow.create!(group: other_group, workflow: other_workflow, is_primary: true)

    sign_in editor
    get workflows_path

    assert_response :success
    assert_no_match "Other Workflow", response.body
  end

  test "regular user is redirected to play from workflows" do
    sign_in @user
    get workflows_path

    assert_redirected_to play_path
  end

  test "admin can see all groups and workflows" do
    sign_in @admin

    get workflows_path

    assert_response :success
    assert_match "Parent Group", response.body
    assert_match "Child Group", response.body
    assert_match "Workflow in Parent", response.body
    assert_match "Workflow in Child", response.body
  end

  test "search works within selected group context" do
    editor = User.create!(
      email: "editor-nav4-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    UserGroup.create!(group: @parent_group, user: editor)
    # Make workflow public
    @workflow1.update!(is_public: true)
    sign_in editor

    get workflows_path, params: { group_id: @parent_group.id, search: "Parent" }

    assert_response :success
    assert_match "Workflow in Parent", response.body
  end
end
