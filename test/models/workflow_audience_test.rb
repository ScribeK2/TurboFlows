require "test_helper"

# Who sees a workflow is decided by the groups it is filed in (Stage 4a). This
# replaced backward_compatibility_test.rb, which pinned the auto-filing into
# Uncategorized that Global retired.
class WorkflowAudienceTest < ActiveSupport::TestCase
  setup do
    @owner = create_user("editor")
    @admin = create_user("admin")
    @regular = create_user("regular")
  end

  test "a workflow with no groups is visible to its owner" do
    workflow = Workflow.create!(title: "Nobody Chosen", user: @owner)

    assert_includes Workflow.visible_to(@owner), workflow
  end

  test "a workflow with no groups is visible to admins" do
    workflow = Workflow.create!(title: "Nobody Chosen", user: @owner)

    assert_includes Workflow.visible_to(@admin), workflow
  end

  test "a workflow filed in a group is not visible to someone outside it" do
    group = Group.create!(name: "Restricted #{SecureRandom.hex(3)}")
    workflow = Workflow.create!(title: "Restricted", user: @owner)
    GroupWorkflow.create!(group: group, workflow: workflow, is_primary: true)

    assert_not_includes Workflow.visible_to(@regular), workflow
  end

  test "a regular user with no groups sees Global workflows" do
    workflow = file_in_global(Workflow.create!(title: "For Everyone", user: @owner))

    assert_includes Workflow.visible_to(@regular), workflow
    assert workflow.can_be_viewed_by?(@regular)
  end

  # Spec Q47. Every editor used to see these through a "no groups" rule.
  test "a published workflow with no groups is hidden from other editors and regular users" do
    workflow = Workflow.create!(title: "Forgotten", user: @owner)

    [create_user("editor"), @regular].each do |user|
      assert_not_includes Workflow.visible_to(user), workflow
      assert_not workflow.can_be_viewed_by?(user)
    end
  end

  test "a subgroup's workflow is visible to someone in its parent group" do
    parent = Group.create!(name: "Parent #{SecureRandom.hex(3)}")
    child = Group.create!(name: "Child", parent: parent)
    workflow = Workflow.create!(title: "Child Flow", user: @owner)
    GroupWorkflow.create!(group: child, workflow: workflow, is_primary: true)
    UserGroup.create!(user: @regular, group: parent)

    assert_includes Workflow.visible_to(@regular), workflow
    assert workflow.can_be_viewed_by?(@regular)
  end

  test "nobody signed in sees any workflow, Global included" do
    file_in_global(Workflow.create!(title: "Global Anyway", user: @owner))

    assert_empty Workflow.visible_to(nil)
  end

  # Spec Q51 — what Public used to allow, carried over to Global.
  test "an editor may edit a Global workflow another editor owns, and nothing else of theirs" do
    other_editor = create_user("editor")
    group = Group.create!(name: "Shared #{SecureRandom.hex(3)}")
    UserGroup.create!(user: other_editor, group: group)
    global_by_editor = file_in_global(Workflow.create!(title: "Editor Global", user: @owner))
    global_by_admin = file_in_global(Workflow.create!(title: "Admin Global", user: @admin))
    grouped = Workflow.create!(title: "Grouped", user: @owner)
    GroupWorkflow.create!(group: group, workflow: grouped, is_primary: true)

    assert global_by_editor.can_be_edited_by?(other_editor)
    assert_not global_by_admin.can_be_edited_by?(other_editor)
    assert_not grouped.can_be_edited_by?(other_editor)
    assert_not global_by_editor.can_be_edited_by?(@regular)
  end

  test "the listing and the per-workflow check agree" do
    group = Group.create!(name: "Agree #{SecureRandom.hex(3)}")
    elsewhere = Group.create!(name: "Elsewhere #{SecureRandom.hex(3)}")
    UserGroup.create!(user: @regular, group: group)
    grouped = Workflow.create!(title: "Grouped", user: @owner)
    GroupWorkflow.create!(group: group, workflow: grouped, is_primary: true)
    outside = Workflow.create!(title: "Outside", user: @owner)
    GroupWorkflow.create!(group: elsewhere, workflow: outside, is_primary: true)
    workflows = [Workflow.create!(title: "Unfiled", user: @owner),
                 file_in_global(Workflow.create!(title: "Global", user: @owner)), grouped, outside]

    [@owner, @admin, @regular, create_user("editor")].each do |user|
      listed = Workflow.visible_to(user).where(id: workflows.map(&:id)).pluck(:id).to_set
      workflows.each do |workflow|
        assert_equal workflow.can_be_viewed_by?(user), listed.include?(workflow.id), "#{user.role} / #{workflow.title}"
      end
    end
  end

  # Dashboard::DataLoader asks this for all of a CSR's teams at once, so it must
  # answer what Workflow.visible_to_members_of answers for each of them.
  test "member_visible_workflow_ids agrees with visible_to_members_of, group by group" do
    tag = SecureRandom.hex(3)
    department = Group.create!(name: "Department #{tag}")
    team = Group.create!(name: "Team #{tag}", parent: department)
    sub_team = Group.create!(name: "Sub-team #{tag}", parent: team)
    elsewhere = Group.create!(name: "Elsewhere #{tag}")
    filed = lambda do |title, group, status: "published"|
      Workflow.create!(title: "#{title} #{tag}", user: @owner, status:).tap do |workflow|
        GroupWorkflow.create!(group:, workflow:, is_primary: true)
      end
    end
    workflows = [filed.call("Department's", department), filed.call("Team's", team),
                 filed.call("Sub-team's", sub_team), filed.call("Elsewhere's", elsewhere),
                 filed.call("Team draft", team, status: "draft"),
                 file_in_global(Workflow.create!(title: "Global's #{tag}", user: @owner))]
    groups = [department, team, sub_team, elsewhere, global_group]
    ids = workflows.map(&:id)

    batched = Group.member_visible_workflow_ids(groups, ids)

    groups.each do |group|
      assert_equal Workflow.visible_to_members_of(group).where(id: ids).pluck(:id).to_set,
                   batched.fetch(group.id), group.name
    end
  end

  test "in_global? reads preloaded groups without a query" do
    workflow = file_in_global(Workflow.create!(title: "Preloaded", user: @owner))
    loaded = Workflow.includes(group_workflows: :group).find(workflow.id)

    assert_queries_count(0) { assert_predicate loaded, :in_global? }
  end

  private

  def create_user(role)
    User.create!(email: "audience-#{role}-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                 password_confirmation: "password123!", role: role)
  end
end
