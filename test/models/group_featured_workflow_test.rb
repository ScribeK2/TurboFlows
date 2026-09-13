require "test_helper"

# A group's standard kit (spec 2026-09-13-group-featured-workflows). A group may
# feature only what its members can already see (Q6), and only what they can see
# holds one of its 8 places (Q18).
class GroupFeaturedWorkflowTest < ActiveSupport::TestCase
  setup do
    @tag = SecureRandom.hex(3)
    @editor = User.create!(email: "featured-editor-#{@tag}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @department = Group.create!(name: "Department #{@tag}")
    @team = Group.create!(name: "Team #{@tag}", parent: @department)
    @sub_team = Group.create!(name: "Sub-team #{@tag}", parent: @team)
    @elsewhere = Group.create!(name: "Elsewhere #{@tag}")
  end

  test "a group can feature its own, its sub-teams' and Global's workflows" do
    own = filed("Own", @team)
    sub_teams = filed("Sub-team's", @sub_team)
    globals = file_in_global(Workflow.create!(title: "Global's #{@tag}", user: @editor))

    [own, sub_teams, globals].each do |workflow|
      assert_predicate feature(workflow), :persisted?, "#{workflow.title} should be featurable"
    end
  end

  test "a group can't feature a workflow filed elsewhere, in its parent, or unpublished" do
    [filed("Elsewhere", @elsewhere), filed("Parent's", @department), filed("Draft", @team, status: "draft")].each do |workflow|
      row = feature(workflow)

      assert_not row.persisted?, "#{workflow.title} should be refused"
      assert_includes row.errors.full_messages.to_sentence, "isn't visible to #{@team.name}'s members"
    end
  end

  test "the same workflow can't be featured twice in one group" do
    workflow = filed("Once", @team)
    feature(workflow)

    assert_not feature(workflow).persisted?
  end

  test "the ninth visible workflow is refused, but one members can't see holds no place" do
    rows = Array.new(GroupFeaturedWorkflow::MAX_PER_GROUP) { |i| feature(filed("Kit #{i}", @team)) }
    ninth = filed("Ninth", @team)

    refused = feature(ninth)
    assert_not refused.persisted?
    assert_includes refused.errors.full_messages, "A team can feature up to 8 workflows"

    rows.first.workflow.update!(status: "draft")
    assert_predicate feature(ninth), :persisted?
  end

  test "hidden_reason says why members can't see a featured workflow" do
    unpublished = feature(filed("Soon unpublished", @team))
    refiled = feature(filed("Soon re-filed", @team))
    shown = feature(filed("Still shown", @team))
    unpublished.workflow.update!(status: "draft")
    GroupWorkflow.where(workflow: refiled.workflow).update_all(group_id: @elsewhere.id)

    visible = Workflow.visible_to_members_of(@team).pluck(:id).to_set

    assert_equal "Unpublished", unpublished.reload.hidden_reason(visible)
    assert_equal "Not filed in this team, its sub-teams or Global", refiled.reload.hidden_reason(visible)
    assert_nil shown.hidden_reason(visible)
  end

  test "deleting the group or the workflow removes what it featured" do
    by_group = feature(filed("Group goes", @sub_team), group: @sub_team)
    by_workflow = feature(filed("Workflow goes", @team))

    @sub_team.destroy!
    by_workflow.workflow.destroy!

    assert_not GroupFeaturedWorkflow.exists?(by_group.id)
    assert_not GroupFeaturedWorkflow.exists?(by_workflow.id)
  end

  test "deleting the person who added it keeps the feature" do
    adder = User.create!(email: "featured-adder-#{@tag}@example.com", password: "password123!",
                         password_confirmation: "password123!", role: "admin")
    row = GroupFeaturedWorkflow.create!(group: @team, workflow: filed("Stays", @team), added_by: adder)

    adder.destroy!

    assert_nil row.reload.added_by
  end

  private

  def filed(title, group, status: "published")
    workflow = Workflow.create!(title: "#{title} #{@tag}", user: @editor, status:)
    GroupWorkflow.create!(group:, workflow:, is_primary: true)
    workflow
  end

  def feature(workflow, group: @team)
    GroupFeaturedWorkflow.create(group:, workflow:, added_by: @editor)
  end
end
