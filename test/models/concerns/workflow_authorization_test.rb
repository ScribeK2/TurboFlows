require "test_helper"

class WorkflowAuthorizationTest < ActiveSupport::TestCase
  setup do
    Bullet.enable = false if defined?(Bullet)

    @admin = User.create!(
      email: "auth-admin-#{SecureRandom.hex(4)}@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    @editor = User.create!(
      email: "auth-editor-#{SecureRandom.hex(4)}@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @other_editor = User.create!(
      email: "auth-editor2-#{SecureRandom.hex(4)}@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @regular_user = User.create!(
      email: "auth-user-#{SecureRandom.hex(4)}@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )

    @group = Group.create!(name: "Auth Test Group #{SecureRandom.hex(4)}")
    @editor.groups << @group
    @regular_user.groups << @group

    @editor_workflow = Workflow.create!(title: "Editor WF", user: @editor)
    @other_editor_workflow = Workflow.create!(title: "Other Editor WF", user: @other_editor)
    @public_workflow = Workflow.create!(title: "Public WF", user: @other_editor, is_public: true)
    @grouped_workflow = Workflow.create!(title: "Grouped WF", user: @other_editor)
    GroupWorkflow.create!(group: @group, workflow: @grouped_workflow, is_primary: true)
  end

  teardown do
    Bullet.enable = true if defined?(Bullet)
  end

  # ── can_be_viewed_by? ──

  test "admin can view all workflows" do
    assert @editor_workflow.can_be_viewed_by?(@admin)
    assert @other_editor_workflow.can_be_viewed_by?(@admin)
    assert @public_workflow.can_be_viewed_by?(@admin)
    assert @grouped_workflow.can_be_viewed_by?(@admin)
  end

  test "editor can view own workflows" do
    assert @editor_workflow.can_be_viewed_by?(@editor)
  end

  test "editor can view public workflows" do
    assert @public_workflow.can_be_viewed_by?(@editor)
  end

  test "editor can view workflows in assigned group" do
    assert @grouped_workflow.can_be_viewed_by?(@editor)
  end

  test "editor cannot view private workflow of another user outside group" do
    private_wf = Workflow.create!(title: "Private WF", user: @admin)
    # Assign to a group the editor is NOT in
    other_group = Group.create!(name: "Other Group #{SecureRandom.hex(4)}")
    GroupWorkflow.create!(group: other_group, workflow: private_wf, is_primary: true)
    refute private_wf.can_be_viewed_by?(@editor)
  end

  test "regular user can view public workflows" do
    assert @public_workflow.can_be_viewed_by?(@regular_user)
  end

  test "regular user can view workflows in assigned group" do
    assert @grouped_workflow.can_be_viewed_by?(@regular_user)
  end

  test "regular user cannot view private workflow outside group" do
    private_wf = Workflow.create!(title: "Private WF", user: @editor)
    other_group = Group.create!(name: "Priv Group #{SecureRandom.hex(4)}")
    GroupWorkflow.create!(group: other_group, workflow: private_wf, is_primary: true)
    refute private_wf.can_be_viewed_by?(@regular_user)
  end

  test "nil user cannot view any workflow" do
    refute @public_workflow.can_be_viewed_by?(nil)
    refute @editor_workflow.can_be_viewed_by?(nil)
  end

  # ── can_be_edited_by? ──

  test "admin can edit all workflows" do
    assert @editor_workflow.can_be_edited_by?(@admin)
    assert @other_editor_workflow.can_be_edited_by?(@admin)
    assert @public_workflow.can_be_edited_by?(@admin)
  end

  test "editor can edit own workflows" do
    assert @editor_workflow.can_be_edited_by?(@editor)
  end

  test "editor can edit public workflows created by other editors" do
    assert @public_workflow.can_be_edited_by?(@editor)
  end

  test "editor cannot edit private workflows of other editors" do
    refute @other_editor_workflow.can_be_edited_by?(@editor)
  end

  test "regular user cannot edit any workflow" do
    refute @editor_workflow.can_be_edited_by?(@regular_user)
    refute @public_workflow.can_be_edited_by?(@regular_user)
  end

  # ── can_be_deleted_by? ──

  test "admin can delete all workflows" do
    assert @editor_workflow.can_be_deleted_by?(@admin)
    assert @other_editor_workflow.can_be_deleted_by?(@admin)
  end

  test "editor can delete own workflows" do
    assert @editor_workflow.can_be_deleted_by?(@editor)
  end

  test "editor cannot delete other editors workflows" do
    refute @other_editor_workflow.can_be_deleted_by?(@editor)
  end

  test "regular user cannot delete any workflow" do
    refute @editor_workflow.can_be_deleted_by?(@regular_user)
    refute @public_workflow.can_be_deleted_by?(@regular_user)
  end
end
