require "test_helper"

class TaggingTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "tagging-test@example.com",
      password: "password123456",
      password_confirmation: "password123456"
    )
    @workflow = Workflow.create!(title: "Tagging WF", user: @user)
    @tag = Tag.create!(name: "Important")
  end

  # Validations
  test "valid with tag and workflow" do
    tagging = Tagging.new(tag: @tag, workflow: @workflow)
    assert tagging.valid?
  end

  test "enforces uniqueness of tag_id scoped to workflow_id" do
    Tagging.create!(tag: @tag, workflow: @workflow)
    duplicate = Tagging.new(tag: @tag, workflow: @workflow)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:tag_id], "has already been taken"
  end

  test "allows same tag with different workflows" do
    workflow2 = Workflow.create!(title: "Tagging WF 2", user: @user)
    Tagging.create!(tag: @tag, workflow: @workflow)
    tagging2 = Tagging.new(tag: @tag, workflow: workflow2)
    assert tagging2.valid?
  end

  test "allows same workflow with different tags" do
    tag2 = Tag.create!(name: "Urgent Tag")
    Tagging.create!(tag: @tag, workflow: @workflow)
    tagging2 = Tagging.new(tag: tag2, workflow: @workflow)
    assert tagging2.valid?
  end

  test "requires tag_id" do
    tagging = Tagging.new(workflow: @workflow)
    assert_not tagging.valid?
  end

  test "requires workflow_id" do
    tagging = Tagging.new(tag: @tag)
    assert_not tagging.valid?
  end

  # Associations
  test "belongs to tag" do
    tagging = Tagging.create!(tag: @tag, workflow: @workflow)
    assert_equal @tag, tagging.tag
  end

  test "belongs to workflow" do
    tagging = Tagging.create!(tag: @tag, workflow: @workflow)
    assert_equal @workflow, tagging.workflow
  end

  # Touch behavior
  test "touching workflow on creation" do
    original_updated_at = @workflow.updated_at
    travel 1.second
    Tagging.create!(tag: @tag, workflow: @workflow)
    @workflow.reload
    assert_not_equal original_updated_at, @workflow.updated_at
  end

  test "touching workflow on update" do
    tagging = Tagging.create!(tag: @tag, workflow: @workflow)
    original_updated_at = @workflow.updated_at
    travel 1.second
    tagging.update!(tag: Tag.create!(name: "Updated"))
    @workflow.reload
    assert_not_equal original_updated_at, @workflow.updated_at
  end

  # Dependent destroy
  test "destroying tag destroys taggings" do
    Tagging.create!(tag: @tag, workflow: @workflow)
    assert_difference("Tagging.count", -1) do
      @tag.destroy
    end
  end

  test "destroying workflow destroys taggings" do
    Tagging.create!(tag: @tag, workflow: @workflow)
    assert_difference("Tagging.count", -1) do
      @workflow.destroy
    end
  end

  # Edge cases
  test "can have multiple taggings for same tag with different workflows" do
    workflow2 = Workflow.create!(title: "Tagging WF 2", user: @user)
    workflow3 = Workflow.create!(title: "Tagging WF 3", user: @user)

    tagging1 = Tagging.create!(tag: @tag, workflow: @workflow)
    tagging2 = Tagging.create!(tag: @tag, workflow: workflow2)
    tagging3 = Tagging.create!(tag: @tag, workflow: workflow3)

    assert_equal 3, Tagging.where(tag: @tag).count
  end

  test "can have multiple taggings for same workflow with different tags" do
    tag2 = Tag.create!(name: "Urgent Tag")
    tag3 = Tag.create!(name: "High Priority Tag")

    tagging1 = Tagging.create!(tag: @tag, workflow: @workflow)
    tagging2 = Tagging.create!(tag: tag2, workflow: @workflow)
    tagging3 = Tagging.create!(tag: tag3, workflow: @workflow)

    assert_equal 3, Tagging.where(workflow: @workflow).count
  end

  test "tag association returns correct workflows through taggings" do
    workflow2 = Workflow.create!(title: "Tagging WF 2", user: @user)
    Tagging.create!(tag: @tag, workflow: @workflow)
    Tagging.create!(tag: @tag, workflow: workflow2)

    workflows = @tag.workflows
    assert_equal 2, workflows.count
    assert_includes workflows, @workflow
    assert_includes workflows, workflow2
  end

  test "workflow association returns correct tags through taggings" do
    tag2 = Tag.create!(name: "Urgent Tag")
    Tagging.create!(tag: @tag, workflow: @workflow)
    Tagging.create!(tag: tag2, workflow: @workflow)

    tags = @workflow.tags
    assert_equal 2, tags.count
    assert_includes tags, @tag
    assert_includes tags, tag2
  end
end
