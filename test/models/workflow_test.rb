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

  # The nightly rollup writes rows that hold a RESTRICT foreign key to the
  # workflow, so a workflow that had ever been rolled up could not be deleted.
  test "destroying a workflow removes its rollups" do
    workflow = Workflow.create!(title: "Rolled Up", user: @user)
    ScenarioRollup.create!(workflow: workflow, day: Date.current, purpose: "live", outcome: "completed",
                           runs_count: 1, duration_sum_seconds: 60, duration_count: 1)
    ScenarioDropoffRollup.create!(workflow: workflow, day: Date.current, step_title: "Ask", runs_count: 1)

    assert_difference -> { ScenarioRollup.count } => -1, -> { ScenarioDropoffRollup.count } => -1 do
      workflow.destroy!
    end
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
      user: @user
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
      user: editor
    )

    assert own_workflow.can_be_viewed_by?(editor)
  end

  test "can_be_viewed_by? should allow editor to view Global workflows" do
    editor = User.create!(
      email: "editor@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    global_workflow = file_in_global(Workflow.create!(title: "Global Workflow", user: @user))

    assert global_workflow.can_be_viewed_by?(editor)
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
      user: @user
    )
    GroupWorkflow.create!(group: Group.create!(name: "Not The Editor's"), workflow: other_workflow, is_primary: true)

    assert_not other_workflow.can_be_viewed_by?(editor)
  end

  test "can_be_viewed_by? should allow user to view Global workflows" do
    regular_user = User.create!(
      email: "user@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
    global_workflow = file_in_global(Workflow.create!(title: "Global Workflow", user: @user))

    assert global_workflow.can_be_viewed_by?(regular_user)
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
      user: @user
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
      user: @user
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
      user: editor
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
      user: @user
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
      user: @user
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
    workflow1 = Workflow.create!(title: "Private", user: @user)
    workflow2 = Workflow.create!(title: "Public", user: @user)

    visible = Workflow.visible_to(admin)

    assert_includes visible.map(&:id), workflow1.id
    assert_includes visible.map(&:id), workflow2.id
  end

  test "visible_to scope should return own + Global for editor" do
    editor = User.create!(
      email: "editor@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    own_unfiled = Workflow.create!(title: "My Unfiled", user: editor)
    own_global = file_in_global(Workflow.create!(title: "My Global", user: editor))
    other_unfiled = Workflow.create!(title: "Other Unfiled", user: @user)
    other_global = file_in_global(Workflow.create!(title: "Other Global", user: @user))

    visible = Workflow.visible_to(editor)

    assert_includes visible.map(&:id), own_unfiled.id
    assert_includes visible.map(&:id), own_global.id
    assert_includes visible.map(&:id), other_global.id
    assert_not_includes visible.map(&:id), other_unfiled.id
  end

  test "visible_to scope should return only Global for a user in no group" do
    regular_user = User.create!(
      email: "user@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
    unfiled_workflow = Workflow.create!(title: "Unfiled", user: @user)
    global_workflow = file_in_global(Workflow.create!(title: "Global", user: @user))

    visible = Workflow.visible_to(regular_user)

    assert_not_includes visible.map(&:id), unfiled_workflow.id
    assert_includes visible.map(&:id), global_workflow.id
  end

  # Group association tests
  test "should have many groups through group_workflows" do
    group1 = Group.create!(name: "Group 1")
    group2 = Group.create!(name: "Group 2")
    workflow = Workflow.create!(title: "Test Workflow", user: @user)

    GroupWorkflow.create!(group: group1, workflow: workflow, is_primary: true)
    GroupWorkflow.create!(group: group2, workflow: workflow, is_primary: false)

    assert_equal 2, workflow.groups.count
    assert_includes workflow.groups.map(&:id), group1.id
    assert_includes workflow.groups.map(&:id), group2.id
  end

  test "primary_group should return primary group" do
    group1 = Group.create!(name: "Primary Group")
    group2 = Group.create!(name: "Secondary Group")
    workflow = Workflow.create!(title: "Test Workflow", user: @user)

    GroupWorkflow.create!(group: group1, workflow: workflow, is_primary: true)
    GroupWorkflow.create!(group: group2, workflow: workflow, is_primary: false)

    workflow.reload
    assert_equal group1, workflow.primary_group
  end

  test "primary_group should return first group if no primary set" do
    group1 = Group.create!(name: "Group 1")
    group2 = Group.create!(name: "Group 2")
    workflow = Workflow.create!(title: "Test Workflow", user: @user)

    GroupWorkflow.create!(group: group1, workflow: workflow, is_primary: false)
    GroupWorkflow.create!(group: group2, workflow: workflow, is_primary: false)

    workflow.reload
    assert_equal group1, workflow.primary_group
  end

  test "all_groups should return all assigned groups" do
    group1 = Group.create!(name: "Group 1")
    group2 = Group.create!(name: "Group 2")
    workflow = Workflow.create!(title: "Test Workflow", user: @user)

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
    workflow = Workflow.create!(title: "Group Workflow", user: @user)

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
    workflow = Workflow.create!(title: "Workflow Without Groups", user: @user)

    visible = Workflow.visible_to(user)

    assert_not_includes visible.map(&:id), workflow.id
  end

  test "visible_to scope should include a Global workflow for a user outside its other groups" do
    user = User.create!(
      email: "user@test.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    group = Group.create!(name: "Other Group")
    global_workflow = Workflow.create!(title: "Global Workflow", user: @user)

    GroupWorkflow.create!(group: group, workflow: global_workflow, is_primary: true)
    file_in_global(global_workflow)

    visible = Workflow.visible_to(user)

    assert_includes visible.map(&:id), global_workflow.id
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
      assert_not_nil workflow.draft_expires_at
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

  # A draft with steps is somebody's work in progress. Step edits do not touch the
  # workflow row -- `Step belongs_to :workflow, counter_cache:` has no `touch:` --
  # so `set_draft_expiration` never refreshes the TTL while a user builds out a
  # graph. Before this scope was gated, a workflow renamed on day one and built
  # out over the next fortnight was destroyed on day eight, steps and all. The
  # previous version of this test asserted exactly that destruction as correct.
  test "expired_drafts excludes drafts that have steps" do
    draft = Workflow.create!(title: "Draft With Steps", user: @user, status: "draft")
    Steps::Resolve.create!(workflow: draft, position: 0, title: "Done", resolution_type: "success")
    draft.update_columns(draft_expires_at: 1.day.ago)

    assert_not_includes Workflow.expired_drafts, draft
  end

  test "cleanup_expired_drafts leaves a draft with steps alone" do
    draft = Workflow.create!(title: "Draft With Steps", user: @user, status: "draft")
    q = Steps::Question.create!(workflow: draft, position: 0, title: "Q1", question: "What?")
    r = Steps::Resolve.create!(workflow: draft, position: 1, title: "Done", resolution_type: "success")
    Transition.create!(step: q, target_step: r, position: 0)
    draft.update!(start_step_id: q.id)
    draft.update_columns(draft_expires_at: 1.day.ago)

    assert_no_difference("Workflow.count") do
      assert_equal 0, Workflow.cleanup_expired_drafts
    end

    assert Workflow.exists?(draft.id)
    assert Step.exists?(q.id)
    assert Step.exists?(r.id)
  end

  # The scope still has a job: an empty draft that was given a title never
  # matches `orphaned_drafts` (which requires the title "Untitled Workflow"), so
  # without this it would linger forever.
  test "cleanup_expired_drafts destroys an expired draft with no steps" do
    draft = Workflow.create!(title: "Named But Empty", user: @user, status: "draft")
    draft.update_columns(draft_expires_at: 1.day.ago)

    assert_difference("Workflow.count", -1) do
      assert_equal 1, Workflow.cleanup_expired_drafts
    end

    assert_not Workflow.exists?(draft.id)
  end

  test "can_resolve persists through update on AR step" do
    workflow = Workflow.create!(title: "Test can_resolve update", user: @user)
    step = Steps::Action.create!(workflow: workflow, position: 0, title: "Act", can_resolve: false)

    step.update!(can_resolve: true)
    assert step.reload.can_resolve

    step.update!(can_resolve: false)
    assert_not step.reload.can_resolve
  end

  test "SAVE_BLOCKING_CODES omits the codes that must not block a save" do
    assert_equal %i[circular_subflow max_depth_exceeded subflow_target_missing].sort,
                 SubflowValidator::SAVE_BLOCKING_CODES.sort
    assert_not_includes SubflowValidator::SAVE_BLOCKING_CODES, :no_resolve_across_workflows,
                        "a half-built bundle is legitimately inescapable and must stay saveable"
  end

  test "a circular sub-flow still blocks save" do
    wf_a = Workflow.create!(title: "Save A", user: @user)
    wf_b = Workflow.create!(title: "Save B", user: @user)
    Steps::SubFlow.create!(workflow: wf_a, position: 0, title: "Call B", sub_flow_workflow_id: wf_b.id)
    Steps::SubFlow.create!(workflow: wf_b, position: 0, title: "Call A", sub_flow_workflow_id: wf_a.id)
    wf_a.reload.title = "Renamed"
    assert_not wf_a.save
    assert(wf_a.errors[:steps].any? { |e| e.include?("Circular sub-flow reference") })
  end
  test "publishing_alongside lets a published workflow reference a draft in the same set" do
    target = Workflow.create!(title: "Set Target", user: @user, status: "draft")
    Steps::Resolve.create!(workflow: target, position: 0, title: "Done", resolution_type: "success")
    source = Workflow.create!(title: "Set Source", user: @user, status: "draft")
    call = Steps::SubFlow.create!(workflow: source, position: 0, title: "Call Target",
                                  sub_flow_workflow_id: target.id)
    done = Steps::Resolve.create!(workflow: source, position: 1, title: "Done",
                                  resolution_type: "success")
    Transition.create!(step: call, target_step: done, position: 0)
    source.update!(start_step: call)

    source.while_publishing do
      assert_not source.valid?, "without the set, a publish may not point at a draft"

      source.publishing_alongside = Set[target.id]
      assert_predicate source, :valid?, source.errors.full_messages.join(" | ")
    end
  end

  test "publishing_alongside is nil by default and changes nothing" do
    target = Workflow.create!(title: "Plain Target", user: @user, status: "draft")
    Steps::Resolve.create!(workflow: target, position: 0, title: "Done", resolution_type: "success")
    source = Workflow.create!(title: "Plain Source", user: @user, status: "draft")
    call = Steps::SubFlow.create!(workflow: source, position: 0, title: "Call Target",
                                  sub_flow_workflow_id: target.id)
    done = Steps::Resolve.create!(workflow: source, position: 1, title: "Done",
                                  resolution_type: "success")
    Transition.create!(step: call, target_step: done, position: 0)
    source.update!(start_step: call)

    assert_nil source.publishing_alongside
    source.while_publishing do
      assert_not source.valid?
      assert(source.errors[:steps].any? { |e| e.include?("is not published") })
    end
  end

  test "publishing_alongside does not excuse a blank or self-referencing target" do
    wf = Workflow.create!(title: "Self Ref", user: @user, status: "draft")
    step = Steps::SubFlow.new(workflow: wf, position: 0, title: "Call Self",
                              sub_flow_workflow_id: wf.id, uuid: SecureRandom.uuid)
    step.save(validate: false)
    # No start_step assignment: a self-referencing workflow cannot be saved at
    # all, which is the point. We only need #valid? to run the validation.
    wf.publishing_alongside = Set[wf.id]
    wf.while_publishing { wf.valid? }
    assert(wf.errors[:steps].any? { |e| e.include?("cannot reference itself") },
           "the set excuses only the published-target rule, nothing else")
  end

  # Between publishes a live workflow can gain a Sub-Flow into a draft; that
  # rule belongs to the next publish, not to a rename.
  test "a published workflow pointing at a draft saves until it is republished" do
    target = Workflow.create!(title: "Live Target", user: @user, status: "draft")
    Steps::Resolve.create!(workflow: target, position: 0, title: "Done", resolution_type: "success")
    source = Workflow.create!(title: "Live Source", user: @user, status: "draft")
    call = Steps::SubFlow.create!(workflow: source, position: 0, title: "Call Target",
                                  sub_flow_workflow_id: target.id)
    done = Steps::Resolve.create!(workflow: source, position: 1, title: "Done",
                                  resolution_type: "success")
    Transition.create!(step: call, target_step: done, position: 0)
    source.update!(start_step: call)
    source.update_column(:status, "published")

    source.reload.title = "Live Source renamed"
    assert_predicate source, :valid?, source.errors.full_messages.join(" | ")
  end
end
