require "test_helper"

class FoldersControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(
      email: "admin-folder-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    @editor = User.create!(
      email: "editor-folder-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @other_editor = User.create!(
      email: "other-editor-folder-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )

    @group = Group.create!(name: "Test Group #{SecureRandom.hex(4)}")
    @other_group = Group.create!(name: "Other Group #{SecureRandom.hex(4)}")

    # Assign @editor to @group only
    UserGroup.create!(user: @editor, group: @group)

    @workflow = Workflow.create!(
      title: "Test Workflow",
      user: @editor,
      steps: [{ type: "action", title: "Step 1", instructions: "Do it" }]
    )

    GroupWorkflow.create!(group: @group, workflow: @workflow)

    @folder = Folder.create!(name: "Target Folder", group: @group)

    sign_in @editor
  end

  test "editor can move workflow within their group" do
    patch move_workflow_folder_path, params: {
      workflow_id: @workflow.id,
      folder_id: @folder.id,
      group_id: @group.id
    }

    assert_redirected_to workflows_path(group_id: @group.id)
    assert_equal @folder, GroupWorkflow.find_by(group: @group, workflow: @workflow).folder
  end

  test "editor cannot move workflow to group they don't belong to" do
    # Create a group_workflow in the other group too so find_by! won't fail first
    GroupWorkflow.create!(group: @other_group, workflow: @workflow)
    other_folder = Folder.create!(name: "Other Folder", group: @other_group)

    patch move_workflow_folder_path, params: {
      workflow_id: @workflow.id,
      folder_id: other_folder.id,
      group_id: @other_group.id
    }

    assert_redirected_to workflows_path
    assert_match(/permission/, flash[:alert])
  end

  test "editor cannot move another user's private workflow" do
    other_workflow = Workflow.create!(
      title: "Other's Workflow",
      user: @other_editor,
      is_public: false,
      steps: [{ type: "action", title: "Step 1", instructions: "Do it" }]
    )
    GroupWorkflow.create!(group: @group, workflow: other_workflow)

    patch move_workflow_folder_path, params: {
      workflow_id: other_workflow.id,
      folder_id: @folder.id,
      group_id: @group.id
    }

    assert_redirected_to workflows_path
    assert_match(/permission/, flash[:alert])
  end

  test "admin can move any workflow to any group" do
    sign_in @admin
    GroupWorkflow.create!(group: @other_group, workflow: @workflow)
    other_folder = Folder.create!(name: "Admin Folder", group: @other_group)

    patch move_workflow_folder_path, params: {
      workflow_id: @workflow.id,
      folder_id: other_folder.id,
      group_id: @other_group.id
    }

    assert_redirected_to workflows_path(group_id: @other_group.id)
  end

  test "regular user cannot move workflows" do
    regular_user = User.create!(
      email: "user-folder-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
    sign_in regular_user

    patch move_workflow_folder_path, params: {
      workflow_id: @workflow.id,
      folder_id: @folder.id,
      group_id: @group.id
    }

    assert_redirected_to workflows_path
    assert_match(/permission/, flash[:alert])
  end
end
