require "test_helper"

# The Teams pages (spec 2026-09-13-group-featured-workflows Q8, Q16, Q17), for
# administrators and the managers of groups, outside the admin area.
class TeamsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tag = SecureRandom.hex(3)
    @global = global_group
    @department = Group.create!(name: "Department #{@tag}")
    @team = Group.create!(name: "Billing #{@tag}", parent: @department)
    @sub_team = Group.create!(name: "Refunds #{@tag}", parent: @team)
    @sibling = Group.create!(name: "Sales #{@tag}", parent: @department)
    @admin = person("admin", "admin")
    @manager = person("manager", "user")
    GroupManager.create!(group: @team, user: @manager)
    @editor = person("editor", "editor")
    @regular = person("regular", "user")
    UserGroup.create!(user: @regular, group: @team)
  end

  test "administrators and managers see Teams in the top bar, current on the Teams pages" do
    [@admin, @manager].each do |user|
      sign_in user

      get teams_path

      assert_response :success, user.email
      assert_select "a.nav__link[href=?][aria-current=page]", teams_path, text: "Teams"
      assert_select ".admin-shell", 0
      sign_out :user
    end
  end

  test "editors and regular users without a grant see no link and are turned away" do
    [@editor, @regular].each do |user|
      sign_in user

      get play_path
      assert_select "a.nav__link", text: "Teams", count: 0

      get teams_path
      assert_redirected_to root_path, user.email

      get team_path(@team)
      assert_redirected_to root_path, user.email
      sign_out :user
    end
  end

  test "a manager's list holds their team and its sub-teams, not the parent, a sibling or Global" do
    sign_in @manager

    get teams_path

    assert_select "#teams-list a[href=?]", team_path(@team)
    assert_select "#teams-list a[href=?]", team_path(@sub_team)
    [@department, @sibling, @global].each { assert_select "#teams-list a[href=?]", team_path(it), count: 0 }
    assert_select "#teams-list a", text: "Department #{@tag} / Billing #{@tag} / Refunds #{@tag}"
  end

  test "an administrator's list holds every group and Global" do
    sign_in @admin

    get teams_path

    [@global, @department, @team, @sub_team, @sibling].each { assert_select "#teams-list a[href=?]", team_path(it) }
  end

  test "the filter narrows the list by any part of a team's path" do
    sign_in @manager

    get teams_path(q: "refunds")

    assert_select "#teams-list a[href=?]", team_path(@sub_team)
    assert_select "#teams-list a[href=?]", team_path(@team), count: 0
  end

  test "a manager opens a sub-team's page but is turned away from the parent, Global and a missing id alike" do
    sign_in @manager

    get team_path(@sub_team)
    assert_response :success

    [@department.id, @global.id, 0].each do |id|
      get team_path(id)
      assert_redirected_to root_path, "team #{id}"
    end
  end

  test "a team page lists its featured workflows in order, with who added them, and marks one members can't see" do
    editor = person("author", "editor")
    first = filed("First", @team, editor)
    second = filed("Second", @team, editor)
    gone = filed("Gone", @team, editor)
    GroupFeaturedWorkflow.create!(group: @team, workflow: second, added_by: @manager, position: 1)
    GroupFeaturedWorkflow.create!(group: @team, workflow: first, added_by: @manager, position: 0)
    GroupFeaturedWorkflow.create!(group: @team, workflow: gone, added_by: @manager, position: 2)
    gone.update!(status: "draft")
    @manager.update!(display_name: "Morgan Manager")
    sign_in @manager

    get team_path(@team)

    assert_select "h1", text: @team.name
    assert_select ".page-header-section__ident", text: %r{Department #{@tag} / Billing #{@tag}}
    assert_select ".page-header-section__ident", text: /1 member/
    titles = css_select("#team-featured .admin-group__name").map { it.text.strip }
    assert_equal ["First #{@tag}", "Second #{@tag}", "Gone #{@tag}"], titles
    assert_select "#team-featured li", text: /Added by Morgan Manager/, count: 3
    assert_select "#team-featured", text: /#{Regexp.escape(@manager.email)}/, count: 0
    assert_select "#team-featured li", text: /Members can't see this.*Unpublished/m, count: 1
  end

  test "a visible row past the first 8 is marked for the curator" do
    editor = person("author", "editor")
    kit = Array.new(GroupFeaturedWorkflow::MAX_PER_GROUP) do |i|
      filed("Kit #{i}", @team, editor).tap { GroupFeaturedWorkflow.create!(group: @team, workflow: it, position: i) }
    end
    Workflow.where(id: kit.first.id).update_all(status: "draft")
    ninth = filed("Ninth", @team, editor)
    GroupFeaturedWorkflow.create!(group: @team, workflow: ninth, position: GroupFeaturedWorkflow::MAX_PER_GROUP)
    Workflow.where(id: kit.first.id).update_all(status: "published")
    sign_in @manager

    get team_path(@team)

    assert_select "#team-featured .badge--warning", count: 1
    assert_select "#team-featured li:last-child", text: /Ninth #{@tag}.*Members can't see this.*Past the first 8/m
  end

  test "Global's team page, for an administrator, says everyone signed in" do
    sign_in @admin

    get team_path(@global)

    assert_response :success
    assert_select ".page-header-section__ident", text: /Everyone signed in/
  end

  private

  def person(label, role)
    User.create!(email: "teams-#{label}-#{@tag}@example.com", password: "password123!",
                 password_confirmation: "password123!", role:)
  end

  def filed(title, group, user)
    workflow = Workflow.create!(title: "#{title} #{@tag}", user:, status: "published")
    GroupWorkflow.create!(group:, workflow:, is_primary: true)
    workflow
  end
end
