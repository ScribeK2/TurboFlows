require "test_helper"

class WorkflowPlacementTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "placement-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @root = Group.create!(name: "Support #{SecureRandom.hex(2)}")
    @child = Group.create!(name: "Tier 2 #{SecureRandom.hex(2)}", parent: @root)
    @folder = Folder.create!(name: "Escalations", group: @child)
    UserGroup.create!(user: @user, group: @root)
    UserGroup.create!(user: @user, group: @child)
  end

  teardown do
    User.where("email LIKE ?", "placement-test-%").destroy_all
    Group.where("name LIKE ? OR name LIKE ?", "Support %", "Tier 2 %").destroy_all
    Tag.where(name: %w[Billing billing Tier-2]).destroy_all
  end

  test "resolves a slash-separated group path" do
    placement = WorkflowPlacement.new(user: @user, groups: ["#{@root.name} / #{@child.name}"])

    result = placement.resolve

    assert_predicate result, :valid?
    assert_equal [@child.id], result.group_ids
  end

  test "resolves a group path given as an array of segments" do
    placement = WorkflowPlacement.new(user: @user, groups: [[@root.name, @child.name]])

    result = placement.resolve

    assert_predicate result, :valid?
    assert_equal [@child.id], result.group_ids
  end

  test "preserves order so the first group becomes primary" do
    placement = WorkflowPlacement.new(user: @user, groups: ["#{@root.name} / #{@child.name}", @root.name])

    result = placement.resolve

    assert_equal [@child.id, @root.id], result.group_ids
  end

  test "an unknown group path is an error naming the missing segment" do
    placement = WorkflowPlacement.new(user: @user, groups: ["#{@root.name} / Nope"])

    result = placement.resolve

    assert_not result.valid?
    assert_equal "unknown_group", result.errors.first[:code]
    assert_equal "#{@root.name} / Nope", result.errors.first[:value]
  end

  test "a group the user cannot see is refused, not silently skipped" do
    hidden = Group.create!(name: "Support #{SecureRandom.hex(2)} Hidden")

    placement = WorkflowPlacement.new(user: @user, groups: [hidden.name])

    result = placement.resolve

    assert_not result.valid?
    assert_equal "group_not_permitted", result.errors.first[:code]
  end

  test "an administrator may place into any group" do
    admin = User.create!(
      email: "placement-test-admin-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    hidden = Group.create!(name: "Support #{SecureRandom.hex(2)} Admin Only")

    result = WorkflowPlacement.new(user: admin, groups: [hidden.name]).resolve

    assert_predicate result, :valid?
    assert_equal [hidden.id], result.group_ids
  end

  test "a folder resolves within the primary group" do
    placement = WorkflowPlacement.new(
      user: @user, groups: ["#{@root.name} / #{@child.name}"], folder: "Escalations"
    )

    result = placement.resolve

    assert_predicate result, :valid?
    assert_equal @folder.id, result.folder_id
  end

  test "a folder that does not exist in the primary group is an error" do
    placement = WorkflowPlacement.new(
      user: @user, groups: ["#{@root.name} / #{@child.name}"], folder: "Nowhere"
    )

    result = placement.resolve

    assert_not result.valid?
    assert_equal "unknown_folder", result.errors.first[:code]
  end

  test "tag names are stripped and deduped case-insensitively" do
    placement = WorkflowPlacement.new(user: @user, groups: [], tags: [" Billing ", "billing", "Tier-2"])

    result = placement.resolve

    assert_predicate result, :valid?
    assert_equal %w[Billing Tier-2], result.tag_names
  end

  test "apply! assigns groups, folder and tags, creating tags that do not exist" do
    workflow = @user.workflows.create!(title: "Placed #{SecureRandom.hex(2)}", status: "draft")
    placement = WorkflowPlacement.new(
      user: @user,
      groups: ["#{@root.name} / #{@child.name}"],
      folder: "Escalations",
      tags: ["billing"]
    )

    assert_difference -> { Tag.count }, 1 do
      placement.apply!(workflow)
    end

    assert_equal [@child.id], workflow.reload.groups.map(&:id)
    assert_equal @folder.id, workflow.group_workflows.find_by(is_primary: true).folder_id
    assert_equal ["billing"], workflow.tags.map(&:name)
  end

  test "a tag differing only in case reuses the existing tag" do
    Tag.create!(name: "Billing")
    workflow = @user.workflows.create!(title: "Cased #{SecureRandom.hex(2)}", status: "draft")
    placement = WorkflowPlacement.new(user: @user, groups: [], tags: ["billing"])

    assert_no_difference -> { Tag.count } do
      placement.apply!(workflow)
    end

    assert_equal ["Billing"], workflow.reload.tags.map(&:name)
  end

  test "apply! refuses to write an invalid placement" do
    workflow = @user.workflows.create!(title: "Unplaced #{SecureRandom.hex(2)}", status: "draft")
    placement = WorkflowPlacement.new(user: @user, groups: ["No Such Group"])

    assert_raises(WorkflowPlacement::InvalidPlacement) { placement.apply!(workflow) }
    assert_empty workflow.reload.groups
  end

  test "apply! re-stating the same primary group with no folder named preserves the existing folder" do
    workflow = @user.workflows.create!(title: "Restated #{SecureRandom.hex(2)}", status: "draft")
    workflow.replace_groups!([@child.id])
    workflow.group_workflows.find_by(is_primary: true).update!(folder_id: @folder.id)
    placement = WorkflowPlacement.new(user: @user, groups: ["#{@root.name} / #{@child.name}"])

    placement.apply!(workflow)

    assert_equal [@child.id], workflow.reload.groups.map(&:id)
    assert_equal @folder.id, workflow.group_workflows.find_by(is_primary: true).folder_id
  end

  test "apply! changing the primary group with no folder named leaves the new group folder-less" do
    workflow = @user.workflows.create!(title: "Regrouped #{SecureRandom.hex(2)}", status: "draft")
    workflow.replace_groups!([@child.id])
    workflow.group_workflows.find_by(is_primary: true).update!(folder_id: @folder.id)
    placement = WorkflowPlacement.new(user: @user, groups: [@root.name])

    placement.apply!(workflow)

    assert_equal [@root.id], workflow.reload.groups.map(&:id)
    assert_nil workflow.group_workflows.find_by(is_primary: true).folder_id
  end

  test "apply! with no groups named leaves an existing group assignment untouched" do
    workflow = @user.workflows.create!(title: "Kept #{SecureRandom.hex(2)}", status: "draft")
    workflow.replace_groups!([@child.id])
    placement = WorkflowPlacement.new(user: @user, groups: [], tags: ["billing"])

    assert_difference -> { Tag.count }, 1 do
      placement.apply!(workflow)
    end

    assert_equal [@child.id], workflow.reload.groups.map(&:id)
    assert_equal ["billing"], workflow.tags.map(&:name)
  end

  test "apply! with no tags named leaves existing tags untouched" do
    existing_tag = Tag.where("LOWER(name) = ?", "billing").first || Tag.create!(name: "Billing")
    workflow = @user.workflows.create!(title: "Tagged #{SecureRandom.hex(2)}", status: "draft")
    workflow.tags = [existing_tag]
    placement = WorkflowPlacement.new(user: @user, groups: ["#{@root.name} / #{@child.name}"])

    assert_no_difference -> { Tag.count } do
      placement.apply!(workflow)
    end

    assert_equal [@child.id], workflow.reload.groups.map(&:id)
    assert_equal [existing_tag.id], workflow.tags.map(&:id)
  end
end
