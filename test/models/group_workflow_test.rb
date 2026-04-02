require "test_helper"

class GroupWorkflowTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "gw-test@example.com",
      password: "password123456",
      password_confirmation: "password123456"
    )
    @workflow = Workflow.create!(title: "GW WF", user: @user)
    @group = Group.create!(name: "GW Group")
  end

  # Validations
  test "valid with group and workflow" do
    gw = GroupWorkflow.new(group: @group, workflow: @workflow)
    assert gw.valid?
  end

  test "enforces uniqueness of group_id scoped to workflow_id" do
    GroupWorkflow.create!(group: @group, workflow: @workflow)
    duplicate = GroupWorkflow.new(group: @group, workflow: @workflow)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:group_id], "has already been taken"
  end

  test "allows same group with different workflows" do
    workflow2 = Workflow.create!(title: "GW WF 2", user: @user)
    GroupWorkflow.create!(group: @group, workflow: @workflow)
    gw2 = GroupWorkflow.new(group: @group, workflow: workflow2)
    assert gw2.valid?
  end

  test "allows same workflow with different groups" do
    group2 = Group.create!(name: "GW Group 2")
    GroupWorkflow.create!(group: @group, workflow: @workflow)
    gw2 = GroupWorkflow.new(group: group2, workflow: @workflow)
    assert gw2.valid?
  end

  test "requires group_id" do
    gw = GroupWorkflow.new(workflow: @workflow)
    assert_not gw.valid?
  end

  test "requires workflow_id" do
    gw = GroupWorkflow.new(group: @group)
    assert_not gw.valid?
  end

  # Associations
  test "belongs to group" do
    gw = GroupWorkflow.create!(group: @group, workflow: @workflow)
    assert_equal @group, gw.group
  end

  test "belongs to workflow" do
    gw = GroupWorkflow.create!(group: @group, workflow: @workflow)
    assert_equal @workflow, gw.workflow
  end

  test "belongs to folder optional" do
    gw = GroupWorkflow.create!(group: @group, workflow: @workflow)
    assert_nil gw.folder
  end

  test "can associate with folder" do
    folder = Folder.create!(name: "Test Folder", group: @group)
    gw = GroupWorkflow.create!(group: @group, workflow: @workflow, folder: folder)
    assert_equal folder, gw.folder
  end

  # Touch behavior
  test "touching workflow on creation" do
    original_updated_at = @workflow.updated_at
    travel 1.second
    GroupWorkflow.create!(group: @group, workflow: @workflow)
    @workflow.reload
    assert_not_equal original_updated_at, @workflow.updated_at
  end

  test "touching workflow on update" do
    gw = GroupWorkflow.create!(group: @group, workflow: @workflow)
    original_updated_at = @workflow.updated_at
    travel 1.second
    gw.update!(is_primary: true)
    @workflow.reload
    assert_not_equal original_updated_at, @workflow.updated_at
  end

  # Dependent destroy
  test "destroying group destroys group_workflows" do
    GroupWorkflow.create!(group: @group, workflow: @workflow)
    assert_difference("GroupWorkflow.count", -1) do
      @group.destroy
    end
  end

  test "destroying workflow destroys group_workflows" do
    workflow_to_destroy = Workflow.create!(title: "GW WF to destroy", user: @user)
    group_for_destroy = Group.create!(name: "GW Group Destroy")
    gw = GroupWorkflow.create!(group: group_for_destroy, workflow: workflow_to_destroy)
    gw_id = gw.id
    workflow_to_destroy.destroy
    assert_nil GroupWorkflow.find_by(id: gw_id)
  end

  # Edge cases
  test "can have multiple group_workflows for same group with different workflows" do
    workflow2 = Workflow.create!(title: "GW WF 2", user: @user)
    workflow3 = Workflow.create!(title: "GW WF 3", user: @user)

    gw1 = GroupWorkflow.create!(group: @group, workflow: @workflow)
    gw2 = GroupWorkflow.create!(group: @group, workflow: workflow2)
    gw3 = GroupWorkflow.create!(group: @group, workflow: workflow3)

    assert_equal 3, GroupWorkflow.where(group: @group).count
  end

  test "can have multiple group_workflows for same workflow with different groups" do
    workflow_test = Workflow.create!(title: "GW WF Test Multi", user: @user)
    group2 = Group.create!(name: "GW Group Multi 2")
    group3 = Group.create!(name: "GW Group Multi 3")

    gw1 = GroupWorkflow.create!(group: @group, workflow: workflow_test)
    gw2 = GroupWorkflow.create!(group: group2, workflow: workflow_test)
    gw3 = GroupWorkflow.create!(group: group3, workflow: workflow_test)

    gws = [@group, group2, group3].map { |g| GroupWorkflow.find_by(group: g, workflow: workflow_test) }
    assert_equal [gw1, gw2, gw3], gws
  end
end
