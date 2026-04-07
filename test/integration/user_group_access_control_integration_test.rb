require "test_helper"

class UserGroupAccessControlIntegrationTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(
      email: "admin-access-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    @user1 = User.create!(
      email: "user1-access-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    @user2 = User.create!(
      email: "user2-access-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    @group1 = Group.create!(name: "Group 1")
    @group2 = Group.create!(name: "Group 2")
    @workflow1 = Workflow.create!(title: "Workflow 1", user: @admin, is_public: false)
    @workflow2 = Workflow.create!(title: "Workflow 2", user: @admin, is_public: false)

    # Remove Uncategorized assignments
    @workflow1.group_workflows.destroy_all
    @workflow2.group_workflows.destroy_all

    GroupWorkflow.create!(group: @group1, workflow: @workflow1, is_primary: true)
    GroupWorkflow.create!(group: @group2, workflow: @workflow2, is_primary: true)
  end

  test "admin can assign groups to users" do
    sign_in @admin

    patch update_groups_admin_user_path(@user1), params: {
      group_ids: [@group1.id]
    }

    assert_redirected_to admin_users_path
    @user1.reload

    assert_includes @user1.groups.map(&:id), @group1.id
  end

  test "editor can only see workflows in assigned groups" do
    editor = User.create!(
      email: "editor-access-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    UserGroup.create!(group: @group1, user: editor)
    sign_in editor

    get workflows_path

    assert_response :success
    assert_match "Workflow 1", response.body
    assert_no_match "Workflow 2", response.body
  end

  test "editor can only see assigned groups in sidebar" do
    editor = User.create!(
      email: "editor-access2-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    UserGroup.create!(group: @group1, user: editor)
    sign_in editor

    get workflows_path

    assert_response :success
    assert_match "Group 1", response.body
    assert_no_match "Group 2", response.body
  end

  test "regular user is redirected to play from workflows" do
    sign_in @user1
    get workflows_path

    assert_redirected_to play_path
  end

  test "admin can bulk assign groups to multiple users" do
    sign_in @admin

    patch bulk_assign_groups_admin_users_path, params: {
      user_ids: [@user1.id, @user2.id],
      group_ids: [@group1.id]
    }

    assert_redirected_to admin_users_path
    @user1.reload
    @user2.reload

    assert_includes @user1.groups.map(&:id), @group1.id
    assert_includes @user2.groups.map(&:id), @group1.id
  end

  test "editor assigned to parent group can see workflows in child groups" do
    editor = User.create!(
      email: "editor-access3-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    parent = Group.create!(name: "Parent")
    child = Group.create!(name: "Child", parent: parent)
    workflow = Workflow.create!(title: "Child Workflow", user: @admin, is_public: true)

    workflow.group_workflows.destroy_all
    GroupWorkflow.create!(group: child, workflow: workflow, is_primary: true)

    UserGroup.create!(group: parent, user: editor)
    sign_in editor

    get workflows_path

    assert_response :success
    assert_match "Child Workflow", response.body
  end

  test "public workflows remain accessible to editors regardless of group assignment" do
    editor = User.create!(
      email: "editor-access4-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    public_workflow = Workflow.create!(title: "Public Workflow", user: @admin, is_public: true)

    public_workflow.group_workflows.destroy_all
    GroupWorkflow.create!(group: @group2, workflow: public_workflow, is_primary: true)

    sign_in editor # Editor not assigned to group2
    get workflows_path

    assert_response :success
    assert_match "Public Workflow", response.body
  end
end
