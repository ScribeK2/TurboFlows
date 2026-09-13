require "test_helper"

# Who curates which groups' featured workflows (spec
# 2026-09-13-group-featured-workflows Q2, Q5, Q13).
class TeamCurationTest < ActiveSupport::TestCase
  setup do
    @tag = SecureRandom.hex(3)
    @global = global_group
    @department = Group.create!(name: "Department #{@tag}")
    @team = Group.create!(name: "Team #{@tag}", parent: @department)
    @sub_team = Group.create!(name: "Sub-team #{@tag}", parent: @team)
    @sibling = Group.create!(name: "Sibling #{@tag}", parent: @department)
  end

  test "an administrator curates every group, Global included" do
    curation = TeamCuration.new(person("admin", "admin"))

    assert_predicate curation, :allowed?
    [@global, @department, @team, @sub_team, @sibling].each { assert curation.can_curate?(it), it.name } # rubocop:disable Minitest/AssertWithExpectedArgument
  end

  test "a manager curates their team and its sub-teams, not the parent, a sibling or Global" do
    manager = person("manager", "user")
    GroupManager.create!(group: @team, user: manager)
    curation = TeamCuration.new(manager)

    assert_predicate curation, :allowed?
    assert curation.can_curate?(@team)
    assert curation.can_curate?(@sub_team)
    [@department, @sibling, @global].each { assert_not curation.can_curate?(it), it.name }
  end

  test "a manager in no group still curates, because managing isn't membership" do
    manager = person("groupless", "editor")
    GroupManager.create!(group: @sibling, user: manager)

    assert_predicate manager, :can_curate_teams?
  end

  test "editors and regular users without a grant curate nothing, even as members" do
    [person("editor", "editor"), person("regular", "user")].each do |user|
      UserGroup.create!(user:, group: @team)
      curation = TeamCuration.new(user)

      assert_not curation.allowed?, user.email
      assert_not curation.can_curate?(@team), user.email
      assert_not user.can_curate_teams?, user.email
    end
  end

  test "nobody curates a missing group" do
    assert_not TeamCuration.new(person("admin2", "admin")).can_curate?(nil)
  end

  test "a manager's team is their managed groups and those groups' sub-teams" do
    manager = person("shared", "user")
    GroupManager.create!(group: @team, user: manager)

    assert_equal [@team.id, @sub_team.id].sort, GroupManager.team_group_ids_for(manager).sort
  end

  private

  def person(label, role)
    User.create!(email: "curation-#{label}-#{@tag}@example.com", password: "password123!",
                 password_confirmation: "password123!", role:)
  end
end
