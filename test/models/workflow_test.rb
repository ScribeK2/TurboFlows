require "test_helper"

class WorkflowTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(
      email: "test@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
  end

  test "should create workflow with valid attributes" do
    workflow = Workflow.new(
      title: "Test Workflow",

      user: @user
    )

    assert_predicate workflow, :valid?
    assert workflow.save
  end

  test "should not create workflow without title" do
    workflow = Workflow.new(
      user: @user
    )

    assert_not workflow.valid?
    assert_includes workflow.errors[:title], "can't be blank"
  end

  test "should not create workflow without user" do
    workflow = Workflow.new(
      title: "Test Workflow"
    )

    assert_not workflow.valid?
    assert_includes workflow.errors[:user], "must exist"
  end

  test "should belong to user" do
    workflow = Workflow.create!(
      title: "Test Workflow",
      user: @user
    )

    assert_equal @user, workflow.user
  end

  test "should store steps as AR records" do
    workflow = Workflow.create!(
      title: "Test Workflow",
      user: @user
    )
    Steps::Question.create!(workflow: workflow, position: 0, title: "Question 1", question: "What is your name?")
    Steps::Action.create!(workflow: workflow, position: 1, title: "Action 1")

    assert_equal 2, workflow.steps.count
    assert_equal "Steps::Question", workflow.steps.first.type
    assert_equal "Action 1", workflow.steps.last.title
  end

  test "recent scope should order by created_at desc" do
    # Clear existing workflows for this test to avoid fixture interference
    Workflow.where(user: @user).destroy_all

    first = Workflow.create!(title: "First", user: @user, created_at: 2.days.ago)
    Workflow.create!(title: "Second", user: @user, created_at: 1.day.ago)
    third = Workflow.create!(title: "Third", user: @user, created_at: Time.current)

    recent = Workflow.where(user: @user).recent.limit(3)

    assert_equal third.id, recent.first.id
    assert_equal first.id, recent.last.id
  end

  # Permission Tests
  test "can_be_viewed_by? should allow admin to view any workflow" do
    admin = User.create!(
      email: "admin@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    private_workflow = Workflow.create!(
      title: "Private Workflow",
      user: @user,
      is_public: false
    )

    assert private_workflow.can_be_viewed_by?(admin)
  end

  test "can_be_viewed_by? should allow editor to view own workflows" do
    editor = User.create!(
      email: "editor@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    own_workflow = Workflow.create!(
      title: "My Workflow",
      user: editor,
      is_public: false
    )

    assert own_workflow.can_be_viewed_by?(editor)
  end

  test "can_be_viewed_by? should allow editor to view public workflows" do
    editor = User.create!(
      email: "editor@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    public_workflow = Workflow.create!(
      title: "Public Workflow",
      user: @user,
      is_public: true
    )

    assert public_workflow.can_be_viewed_by?(editor)
  end

  test "can_be_viewed_by? should not allow editor to view other user's private workflows" do
    editor = User.create!(
      email: "editor@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    other_workflow = Workflow.create!(
      title: "Other User's Workflow",
      user: @user,
      is_public: false
    )

    assert_not other_workflow.can_be_viewed_by?(editor)
  end

  test "can_be_viewed_by? should allow user to view public workflows" do
    regular_user = User.create!(
      email: "user@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
    public_workflow = Workflow.create!(
      title: "Public Workflow",
      user: @user,
      is_public: true
    )

    assert public_workflow.can_be_viewed_by?(regular_user)
  end

  test "can_be_viewed_by? should not allow user to view private workflows" do
    regular_user = User.create!(
      email: "user@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
    private_workflow = Workflow.create!(
      title: "Private Workflow",
      user: @user,
      is_public: false
    )

    assert_not private_workflow.can_be_viewed_by?(regular_user)
  end

  test "can_be_edited_by? should allow admin to edit any workflow" do
    admin = User.create!(
      email: "admin@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    workflow = Workflow.create!(
      title: "Any Workflow",
      user: @user,
      is_public: false
    )

    assert workflow.can_be_edited_by?(admin)
  end

  test "can_be_edited_by? should allow editor to edit own workflows" do
    editor = User.create!(
      email: "editor@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    own_workflow = Workflow.create!(
      title: "My Workflow",
      user: editor,
      is_public: false
    )

    assert own_workflow.can_be_edited_by?(editor)
  end

  test "can_be_edited_by? should not allow editor to edit other user's workflows" do
    editor = User.create!(
      email: "editor@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    other_workflow = Workflow.create!(
      title: "Other User's Workflow",
      user: @user,
      is_public: true
    )

    assert_not other_workflow.can_be_edited_by?(editor)
  end

  test "can_be_edited_by? should not allow user to edit workflows" do
    regular_user = User.create!(
      email: "user@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
    workflow = Workflow.create!(
      title: "Any Workflow",
      user: @user,
      is_public: true
    )

    assert_not workflow.can_be_edited_by?(regular_user)
  end

  test "can_be_deleted_by? should follow same rules as edit" do
    admin = User.create!(
      email: "admin@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    editor = User.create!(
      email: "editor@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    regular_user = User.create!(
      email: "user@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )

    own_workflow = Workflow.create!(title: "My Workflow", user: editor)
    other_workflow = Workflow.create!(title: "Other Workflow", user: @user)

    assert other_workflow.can_be_deleted_by?(admin)
    assert own_workflow.can_be_deleted_by?(editor)
    assert_not other_workflow.can_be_deleted_by?(editor)
    assert_not other_workflow.can_be_deleted_by?(regular_user)
  end

  test "visible_to scope should return all workflows for admin" do
    admin = User.create!(
      email: "admin@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    workflow1 = Workflow.create!(title: "Private", user: @user, is_public: false)
    workflow2 = Workflow.create!(title: "Public", user: @user, is_public: true)

    visible = Workflow.visible_to(admin)

    assert_includes visible.map(&:id), workflow1.id
    assert_includes visible.map(&:id), workflow2.id
  end

  test "visible_to scope should return own + public for editor" do
    editor = User.create!(
      email: "editor@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    own_private = Workflow.create!(title: "My Private", user: editor, is_public: false)
    own_public = Workflow.create!(title: "My Public", user: editor, is_public: true)
    other_private = Workflow.create!(title: "Other Private", user: @user, is_public: false)
    other_public = Workflow.create!(title: "Other Public", user: @user, is_public: true)

    visible = Workflow.visible_to(editor)

    assert_includes visible.map(&:id), own_private.id
    assert_includes visible.map(&:id), own_public.id
    assert_includes visible.map(&:id), other_public.id
    assert_not_includes visible.map(&:id), other_private.id
  end

  test "visible_to scope should return only public for user" do
    regular_user = User.create!(
      email: "user@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
    private_workflow = Workflow.create!(title: "Private", user: @user, is_public: false)
    public_workflow = Workflow.create!(title: "Public", user: @user, is_public: true)

    visible = Workflow.visible_to(regular_user)

    assert_not_includes visible.map(&:id), private_workflow.id
    assert_includes visible.map(&:id), public_workflow.id
  end

  test "public_workflows scope should return only public workflows" do
    public1 = Workflow.create!(title: "Public 1", user: @user, is_public: true)
    public2 = Workflow.create!(title: "Public 2", user: @user, is_public: true)
    private_workflow = Workflow.create!(title: "Private", user: @user, is_public: false)

    public_workflows = Workflow.public_workflows

    assert_includes public_workflows.map(&:id), public1.id
    assert_includes public_workflows.map(&:id), public2.id
    assert_not_includes public_workflows.map(&:id), private_workflow.id
  end

  # Group association tests
  test "should have many groups through group_workflows" do
    group1 = Group.create!(name: "Group 1")
    group2 = Group.create!(name: "Group 2")
    workflow = Workflow.create!(title: "Test Workflow", user: @user)

    # Clear auto-assigned Uncategorized group
    workflow.group_workflows.destroy_all

    GroupWorkflow.create!(group: group1, workflow: workflow, is_primary: true)
    GroupWorkflow.create!(group: group2, workflow: workflow, is_primary: false)

    assert_equal 2, workflow.groups.count
    assert_includes workflow.groups.map(&:id), group1.id
    assert_includes workflow.groups.map(&:id), group2.id
  end

  test "should assign to Uncategorized group when created without groups" do
    workflow = Workflow.create!(title: "Test Workflow", user: @user)

    assert_predicate workflow.groups, :any?
    assert_equal "Uncategorized", workflow.groups.first.name
  end

  test "primary_group should return primary group" do
    group1 = Group.create!(name: "Primary Group")
    group2 = Group.create!(name: "Secondary Group")
    workflow = Workflow.create!(title: "Test Workflow", user: @user)

    # Clear auto-assigned Uncategorized group
    workflow.group_workflows.destroy_all

    GroupWorkflow.create!(group: group1, workflow: workflow, is_primary: true)
    GroupWorkflow.create!(group: group2, workflow: workflow, is_primary: false)

    workflow.reload
    assert_equal group1, workflow.primary_group
  end

  test "primary_group should return first group if no primary set" do
    group1 = Group.create!(name: "Group 1")
    group2 = Group.create!(name: "Group 2")
    workflow = Workflow.create!(title: "Test Workflow", user: @user)

    # Remove Uncategorized assignment
    workflow.group_workflows.destroy_all

    GroupWorkflow.create!(group: group1, workflow: workflow, is_primary: false)
    GroupWorkflow.create!(group: group2, workflow: workflow, is_primary: false)

    workflow.reload
    assert_equal group1, workflow.primary_group
  end

  test "all_groups should return all assigned groups" do
    group1 = Group.create!(name: "Group 1")
    group2 = Group.create!(name: "Group 2")
    workflow = Workflow.create!(title: "Test Workflow", user: @user)

    # Remove Uncategorized assignment
    workflow.group_workflows.destroy_all

    GroupWorkflow.create!(group: group1, workflow: workflow, is_primary: true)
    GroupWorkflow.create!(group: group2, workflow: workflow, is_primary: false)

    all_groups = workflow.all_groups

    assert_equal 2, all_groups.count
    assert_includes all_groups.map(&:id), group1.id
    assert_includes all_groups.map(&:id), group2.id
  end

  test "in_group scope should filter workflows by group" do
    group1 = Group.create!(name: "Group 1")
    group2 = Group.create!(name: "Group 2")
    workflow1 = Workflow.create!(title: "Workflow 1", user: @user)
    workflow2 = Workflow.create!(title: "Workflow 2", user: @user)

    # Remove Uncategorized assignments
    workflow1.group_workflows.destroy_all
    workflow2.group_workflows.destroy_all

    GroupWorkflow.create!(group: group1, workflow: workflow1, is_primary: true)
    GroupWorkflow.create!(group: group2, workflow: workflow2, is_primary: true)

    group1_workflows = Workflow.in_group(group1)

    assert_includes group1_workflows.map(&:id), workflow1.id
    assert_not_includes group1_workflows.map(&:id), workflow2.id
  end

  test "in_group scope should include workflows in descendant groups" do
    parent = Group.create!(name: "Parent")
    child = Group.create!(name: "Child", parent: parent)
    workflow1 = Workflow.create!(title: "Workflow 1", user: @user)
    workflow2 = Workflow.create!(title: "Workflow 2", user: @user)

    # Remove Uncategorized assignments
    workflow1.group_workflows.destroy_all
    workflow2.group_workflows.destroy_all

    GroupWorkflow.create!(group: parent, workflow: workflow1, is_primary: true)
    GroupWorkflow.create!(group: child, workflow: workflow2, is_primary: true)

    parent_workflows = Workflow.in_group(parent)

    assert_includes parent_workflows.map(&:id), workflow1.id
    assert_includes parent_workflows.map(&:id), workflow2.id
  end

  test "visible_to scope should include workflows in user's assigned groups" do
    user = User.create!(
      email: "user@test.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    group = Group.create!(name: "Assigned Group")
    workflow = Workflow.create!(title: "Group Workflow", user: @user, is_public: false)

    # Remove Uncategorized assignment
    workflow.group_workflows.destroy_all
    GroupWorkflow.create!(group: group, workflow: workflow, is_primary: true)
    UserGroup.create!(group: group, user: user)

    visible = Workflow.visible_to(user)

    assert_includes visible.map(&:id), workflow.id
  end

  test "visible_to scope should not include ungrouped private workflows for regular users" do
    user = User.create!(
      email: "user@test.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    workflow = Workflow.create!(title: "Workflow Without Groups", user: @user, is_public: false)

    # Remove all group assignments
    workflow.group_workflows.destroy_all

    visible = Workflow.visible_to(user)

    assert_not_includes visible.map(&:id), workflow.id
  end

  test "visible_to scope should always include public workflows regardless of groups" do
    user = User.create!(
      email: "user@test.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    group = Group.create!(name: "Other Group")
    public_workflow = Workflow.create!(title: "Public Workflow", user: @user, is_public: true)

    # Remove Uncategorized assignment and assign to different group
    public_workflow.group_workflows.destroy_all
    GroupWorkflow.create!(group: group, workflow: public_workflow, is_primary: true)

    visible = Workflow.visible_to(user)

    assert_includes visible.map(&:id), public_workflow.id
  end

  # can_resolve tests (AR Step model — boolean column handles casting natively)
  test "can_resolve on AR action step" do
    workflow = Workflow.create!(title: "Test can_resolve", user: @user)
    step = Steps::Action.create!(workflow: workflow, position: 0, title: "Fix it", can_resolve: true)

    assert step.can_resolve
  end

  test "can_resolve defaults to false on AR steps" do
    workflow = Workflow.create!(title: "Test can_resolve default", user: @user)
    step = Steps::Action.create!(workflow: workflow, position: 0, title: "Fix it")

    assert_not step.can_resolve
  end

  test "can_resolve on AR message step" do
    workflow = Workflow.create!(title: "Test can_resolve message", user: @user)
    step = Steps::Message.create!(workflow: workflow, position: 0, title: "Info")
    step.update!(can_resolve: true)

    assert step.reload.can_resolve
  end

  test "orphaned_drafts scope returns untitled drafts with no steps older than 24 hours" do
    # Orphaned: draft, untitled, no steps, > 24h old
    orphan = Workflow.create!(title: "Untitled Workflow", user: @user, status: "draft")
    orphan.update_column(:created_at, 2.days.ago)

    # Not orphaned: has steps
    with_steps = Workflow.create!(title: "Untitled Workflow", user: @user, status: "draft")
    with_steps.update_column(:created_at, 2.days.ago)
    Steps::Resolve.create!(workflow: with_steps, position: 0, title: "Done", resolution_type: "success")

    # Not orphaned: renamed
    renamed = Workflow.create!(title: "My Flow", user: @user, status: "draft")
    renamed.update_column(:created_at, 2.days.ago)

    # Not orphaned: too recent
    recent = Workflow.create!(title: "Untitled Workflow", user: @user, status: "draft")

    results = Workflow.orphaned_drafts
    assert_includes results, orphan
    assert_not_includes results, with_steps
    assert_not_includes results, renamed
    assert_not_includes results, recent
  end

  test "cleanup_orphaned_drafts destroys orphaned drafts and returns count" do
    orphan1 = Workflow.create!(title: "Untitled Workflow", user: @user, status: "draft")
    orphan1.update_column(:created_at, 2.days.ago)
    orphan2 = Workflow.create!(title: "Untitled Workflow", user: @user, status: "draft")
    orphan2.update_column(:created_at, 3.days.ago)

    # Should not be destroyed: has steps
    keeper = Workflow.create!(title: "Untitled Workflow", user: @user, status: "draft")
    keeper.update_column(:created_at, 2.days.ago)
    Steps::Resolve.create!(workflow: keeper, position: 0, title: "Done", resolution_type: "success")

    assert_difference("Workflow.count", -2) do
      count = Workflow.cleanup_orphaned_drafts
      assert_equal 2, count
    end

    assert_not Workflow.exists?(orphan1.id)
    assert_not Workflow.exists?(orphan2.id)
    assert Workflow.exists?(keeper.id)
  end

  test "find_or_create_draft_for creates a new draft when none exists" do
    assert_difference("Workflow.count", 1) do
      workflow = Workflow.find_or_create_draft_for(@user)
      assert_predicate workflow, :persisted?
      assert_equal "draft", workflow.status
      assert_equal "Untitled Workflow", workflow.title
      assert_predicate workflow.graph_mode?, :present?
    end
  end

  test "find_or_create_draft_for reuses existing blank draft" do
    existing = Workflow.create!(title: "Untitled Workflow", user: @user, status: "draft", graph_mode: true)

    assert_no_difference("Workflow.count") do
      workflow = Workflow.find_or_create_draft_for(@user)
      assert_equal existing.id, workflow.id
    end
  end

  test "find_or_create_draft_for creates new draft when existing draft has steps" do
    existing = Workflow.create!(title: "Untitled Workflow", user: @user, status: "draft", graph_mode: true)
    Steps::Resolve.create!(workflow: existing, position: 0, title: "Done", resolution_type: "success")

    assert_difference("Workflow.count", 1) do
      workflow = Workflow.find_or_create_draft_for(@user)
      assert_not_equal existing.id, workflow.id
    end
  end

  test "find_or_create_draft_for creates new draft when existing draft is renamed" do
    Workflow.create!(title: "My Custom Flow", user: @user, status: "draft", graph_mode: true)

    assert_difference("Workflow.count", 1) do
      workflow = Workflow.find_or_create_draft_for(@user)
      assert_equal "Untitled Workflow", workflow.title
    end
  end

  test "find_or_create_draft_for refreshes draft_expires_at on reuse" do
    existing = Workflow.create!(title: "Untitled Workflow", user: @user, status: "draft", graph_mode: true)
    old_expiry = existing.draft_expires_at

    travel 1.day do
      workflow = Workflow.find_or_create_draft_for(@user)
      assert_equal existing.id, workflow.id
      assert_operator workflow.draft_expires_at, :>, old_expiry
    end
  end

  test "find_or_create_draft_for does not reuse another user's draft" do
    other_user = User.create!(
      email: "other-dedup-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    Workflow.create!(title: "Untitled Workflow", user: other_user, status: "draft", graph_mode: true)

    assert_difference("Workflow.count", 1) do
      workflow = Workflow.find_or_create_draft_for(@user)
      assert_equal @user.id, workflow.user_id
    end
  end

  test "cleanup_expired_drafts handles drafts with steps and associations" do
    draft = Workflow.create!(title: "Draft With Steps", user: @user, status: "draft")
    q = Steps::Question.create!(workflow: draft, position: 0, title: "Q1", question: "What?")
    r = Steps::Resolve.create!(workflow: draft, position: 1, title: "Done", resolution_type: "success")
    Transition.create!(step: q, target_step: r, position: 0)
    draft.update!(start_step_id: q.id)
    draft.update_columns(draft_expires_at: 1.day.ago)

    assert_difference("Workflow.count", -1) do
      count = Workflow.cleanup_expired_drafts
      assert_equal 1, count
    end

    assert_not Workflow.exists?(draft.id)
    assert_not Step.exists?(q.id)
    assert_not Step.exists?(r.id)
  end

  test "can_resolve persists through update on AR step" do
    workflow = Workflow.create!(title: "Test can_resolve update", user: @user)
    step = Steps::Action.create!(workflow: workflow, position: 0, title: "Act", can_resolve: false)

    step.update!(can_resolve: true)
    assert step.reload.can_resolve

    step.update!(can_resolve: false)
    assert_not step.reload.can_resolve
  end
end
