require "test_helper"

class AnalyticsScopeTest < ActiveSupport::TestCase
  setup do
    @tag = SecureRandom.hex(3)
    @department = Group.create!(name: "Scope Dept #{@tag}")
    @team = Group.create!(name: "Scope Team #{@tag}", parent: @department)
    @sub_team = Group.create!(name: "Scope Sub #{@tag}", parent: @team)
    @sibling = Group.create!(name: "Scope Sibling #{@tag}", parent: @department)

    @admin = person("admin", role: "admin")
    @manager = person("manager")
    GroupManager.create!(group: @team, user: @manager)
    @csr = person("csr", groups: [@team])
    @sub_csr = person("sub", groups: [@sub_team])
    @sibling_csr = person("sibling", groups: [@sibling])
    @department_csr = person("dept", groups: [@department])
    @outsider = person("outsider")

    @workflow = Workflow.create!(title: "Scope Flow #{@tag}", user: @admin)
    @runs = [@csr, @sub_csr, @sibling_csr, @department_csr, @outsider].index_with { run_by(it) }
    @anonymous = run_by(nil)
  end

  def person(label, role: "user", groups: [])
    user = User.create!(email: "scope-#{label}-#{@tag}@example.com", password: "password123!",
                        password_confirmation: "password123!", role:)
    groups.each { UserGroup.create!(user:, group: it) }
    user
  end

  def run_by(user, handed_off_from: nil)
    Scenario.create!(workflow: @workflow, user:, purpose: "live", status: "completed", outcome: "resolved",
                     handed_off_from:, started_at: 1.day.ago, completed_at: 1.day.ago,
                     execution_path: [], results: {}, inputs: {})
  end

  test "an administrator sees every run, anonymous ones included, and All time" do
    scope = AnalyticsScope.new(@admin)

    assert_predicate scope, :allowed?
    assert_predicate scope, :everyone?
    assert_predicate scope, :all_time?
    assert_includes scope.scenarios, @anonymous
    assert_equal Scenario.count, scope.scenarios.count
    assert_empty scope.team_names
  end

  test "a manager sees their team and its sub-teams, and nobody beside or above it" do
    scope = AnalyticsScope.new(@manager)

    assert_predicate scope, :allowed?
    assert_not scope.everyone?
    assert_not scope.all_time?
    assert_equal [@runs[@csr], @runs[@sub_csr]].map(&:id).sort, scope.scenarios.pluck(:id).sort
    assert scope.includes_agent?(@csr)
    assert scope.includes_agent?(@sub_csr)
    assert_not scope.includes_agent?(@sibling_csr), "a sibling team is another manager's"
    assert_not scope.includes_agent?(@department_csr), "reach runs down, never up"
    assert_not scope.includes_agent?(@outsider)
    assert_not scope.includes_agent?(nil)
    assert_not scope.includes_run?(@anonymous)
    assert_equal [@team.name], scope.team_names
  end

  test "every frame of a handed-off call stays in scope" do
    handed_to = run_by(@csr, handed_off_from: @runs[@csr])
    scope = AnalyticsScope.new(@manager)

    assert scope.includes_run?(@runs[@csr])
    assert scope.includes_run?(handed_to)
  end

  test "a CSR who moves teams takes their history with them" do
    UserGroup.find_by!(user: @csr, group: @team).destroy!
    UserGroup.create!(user: @csr, group: @sibling)

    assert_not AnalyticsScope.new(@manager).includes_run?(@runs[@csr])
  end

  test "someone with no grant sees nothing, whatever their role or groups" do
    editor = person("editor", role: "editor", groups: [@team])

    [editor, @csr, nil].each do |user|
      scope = AnalyticsScope.new(user)

      assert_not scope.allowed?
      assert_empty scope.scenarios
      assert_not scope.includes_run?(@runs[@csr])
      assert_not scope.includes_run?(nil)
    end
  end
end
