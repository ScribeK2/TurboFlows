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
          description: "A new group"
        }
      }
    end
    assert_redirected_to admin_group_path(Group.find_by!(name: "New Group"))
  end

  test "admin should be able to create a subgroup" do
    sign_in @admin
    parent = Group.create!(name: "Parent Group")

    assert_difference("Group.count", 1) do
      post admin_groups_path, params: {
        group: {
          name: "Child Group",
          description: "A child group",
          parent_id: parent.id
        }
      }
    end

    child = Group.find_by!(name: "Child Group", parent: parent)

    assert_equal parent.id, child.parent_id
    assert_redirected_to admin_group_path(child)
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

    assert_redirected_to admin_group_path(group)
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

    assert_redirected_to admin_group_path(parent)
    assert_match(/Can't delete/, flash[:alert])
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

    assert_redirected_to admin_group_path(group)
    assert_match(/Can't delete/, flash[:alert])
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

  test "a group's breadcrumb names each parent group, root first, with no list markers" do
    sign_in @admin
    root = Group.create!(name: "Crumb Root #{SecureRandom.hex(3)}")
    mid = Group.create!(name: "Crumb Mid", parent: root)
    leaf = Group.create!(name: "Crumb Leaf", parent: mid)

    get admin_group_path(leaf)

    assert_response :success
    assert_select "nav.wf-breadcrumb ol", 0
    crumbs = css_select("nav.wf-breadcrumb a").map { it.text.strip }
    assert_equal ["Groups", root.name, "Crumb Mid"], crumbs
    assert_select "nav.wf-breadcrumb [aria-current=page]", text: "Crumb Leaf"
    assert_no_match(/Back to Groups/, response.body)
  end

  test "the new and edit group forms sit in the narrow column under a breadcrumb" do
    sign_in @admin
    group = Group.create!(name: "Form Crumb #{SecureRandom.hex(3)}")

    get new_admin_group_path(parent_id: group.id)
    assert_select ".page-narrow nav.wf-breadcrumb a", text: group.name
    assert_select ".page-narrow nav.wf-breadcrumb [aria-current=page]", text: "New subgroup"

    get edit_admin_group_path(group)
    assert_select ".page-narrow nav.wf-breadcrumb [aria-current=page]", text: "Edit"
  end

  test "Global can be neither deleted nor renamed" do
    sign_in @admin
    global = global_group

    assert_no_difference("Group.count") { delete admin_group_path(global) }
    assert_redirected_to admin_group_path(global)
    assert_equal "Global can't be deleted", flash[:alert]

    patch admin_group_path(global), params: { group: { name: "Everyone" } }

    assert_response :unprocessable_content
    assert_equal Group::GLOBAL_NAME, global.reload.name
  end

  test "a group's admin page links to its team page" do
    sign_in @admin
    group = Group.create!(name: "Linked Team #{SecureRandom.hex(3)}")

    get admin_group_path(group)

    assert_select "a[href=?]", team_path(group), text: "Featured workflows (team page)"
  end
end
