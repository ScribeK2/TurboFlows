require "test_helper"

class Admin::GroupsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(
      email: "admin-groups-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    @editor = User.create!(
      email: "editor-groups-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
  end

  test "admin should be able to access groups index" do
    sign_in @admin
    get admin_groups_path

    assert_response :success
  end

  test "non-admin should not be able to access groups index" do
    sign_in @editor
    get admin_groups_path

    assert_redirected_to root_path
    assert_equal "You don't have permission to access this page.", flash[:alert]
  end

  test "admin should be able to create a group" do
    sign_in @admin
    assert_difference("Group.count", 1) do
      post admin_groups_path, params: {
        group: {
          name: "New Group",
          description: "A new group",
          position: 1
        }
      }
    end
    # Controller redirects to index after successful creation
    assert_redirected_to admin_groups_path
  end

  test "admin should be able to create a subgroup" do
    sign_in @admin
    parent = Group.create!(name: "Parent Group")

    assert_difference("Group.count", 1) do
      post admin_groups_path, params: {
        group: {
          name: "Child Group",
          description: "A child group",
          parent_id: parent.id,
          position: 1
        }
      }
    end

    child = Group.last

    assert_equal parent.id, child.parent_id
    # Controller redirects to index after successful creation
    assert_redirected_to admin_groups_path
  end

  test "admin should be able to update a group" do
    sign_in @admin
    group = Group.create!(name: "Original Name", description: "Original description")

    patch admin_group_path(group), params: {
      group: {
        name: "Updated Name",
        description: "Updated description"
      }
    }

    # Controller redirects to index after successful update
    assert_redirected_to admin_groups_path
    group.reload

    assert_equal "Updated Name", group.name
    assert_equal "Updated description", group.description
  end

  test "admin should be able to delete a group without children or workflows" do
    sign_in @admin
    group = Group.create!(name: "To Delete")

    assert_difference("Group.count", -1) do
      delete admin_group_path(group)
    end

    assert_redirected_to admin_groups_path
  end

  test "admin should not be able to delete a group with children" do
    sign_in @admin
    parent = Group.create!(name: "Parent")
    Group.create!(name: "Child", parent: parent)

    assert_no_difference("Group.count") do
      delete admin_group_path(parent)
    end

    assert_redirected_to admin_groups_path
    # Controller uses full message with group name
    assert_match(/Cannot delete group/, flash[:alert])
    assert_match(/subgroups/, flash[:alert])
  end

  test "admin should not be able to delete a group with workflows" do
    sign_in @admin
    user = User.create!(
      email: "user-#{SecureRandom.hex(4)}@test.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    group = Group.create!(name: "Group With Workflows")
    workflow = Workflow.create!(title: "Test Workflow", user: user)
    GroupWorkflow.create!(group: group, workflow: workflow, is_primary: true)

    assert_no_difference("Group.count") do
      delete admin_group_path(group)
    end

    assert_redirected_to admin_groups_path
    # Controller uses full message with group name
    assert_match(/Cannot delete group/, flash[:alert])
    assert_match(/workflows/, flash[:alert])
  end

  test "admin should be able to view a group" do
    sign_in @admin
    group = Group.create!(name: "Test Group", description: "Test description")

    get admin_group_path(group)

    assert_response :success
    assert_match "Test Group", response.body
  end

  test "should prevent circular reference when updating parent" do
    sign_in @admin
    parent = Group.create!(name: "Parent")
    child = Group.create!(name: "Child", parent: parent)

    patch admin_group_path(parent), params: {
      group: {
        parent_id: child.id
      }
    }

    # The update should fail, rendering the edit form (unprocessable_content)
    assert_response :unprocessable_content
    # Parent should still have no parent_id (update failed)
    assert_nil parent.reload.parent_id
  end
end
