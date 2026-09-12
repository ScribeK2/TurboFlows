require "test_helper"

# Managers are set on the group page (spec 2026-09-12), built as members are: a
# search that stays open, Add per result, Remove with no confirm, the card
# streamed back whole with a flash naming who changed.
class Admin::GroupManagersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tag = SecureRandom.hex(4)
    @admin = person("admin", role: "admin")
    sign_in @admin
    @group = Group.create!(name: "Managers Team #{@tag}")
    @ada = person("ada", display_name: "Ada Lovelace")
    @bob = person("bob")
  end

  test "the search finds people by email or name, leaving out managers and deactivated accounts" do
    GroupManager.create!(user: @bob, group: @group)
    person("gone").deactivate!

    get admin_group_managers_path(@group, q: @tag)

    assert_response :success
    found = css_select("turbo-frame#group-manager-search .admin-group__name").map { it.text.strip }
    assert_equal [@ada.email, @admin.email].sort, found.sort
  end

  test "Add streams the manager in, keeps the search open, and names them" do
    post admin_group_managers_path(@group), params: { user_id: @ada.id, q: "ada-#{@tag}" }, as: :turbo_stream

    assert_response :success
    assert GroupManager.exists?(user: @ada, group: @group)
    card = stream_content("group-managers", action: "replace")
    listed = card.css("section > .card__body > .admin-group__list .admin-group__name").map { it.text.strip }
    assert_equal [@ada.email], listed
    assert_equal "ada-#{@tag}", card.at_css("input[name=q]")["value"]
    assert_match "#{@ada.email} now manages #{@group.name}.", stream_content("flash", action: "update").text
  end

  test "a deactivated account cannot be granted a manager slot by a hand-built POST" do
    deactivated = person("gone")
    deactivated.deactivate!

    post admin_group_managers_path(@group), params: { user_id: deactivated.id }, as: :turbo_stream

    assert_response :not_found
    assert_not GroupManager.exists?(user: deactivated, group: @group)
  end

  test "Remove streams the card back without them" do
    grant = GroupManager.create!(user: @ada, group: @group)

    delete admin_group_manager_path(@group, grant), as: :turbo_stream

    assert_not GroupManager.exists?(grant.id)
    assert_empty stream_content("group-managers", action: "replace").css(".admin-group__list .admin-group__name")
    assert_match "#{@ada.email} no longer manages #{@group.name}.", stream_content("flash", action: "update").text
  end

  test "Global takes no managers" do
    post admin_group_managers_path(global_group), params: { user_id: @ada.id }, as: :turbo_stream

    assert_not GroupManager.exists?(user: @ada)
    assert_match "Global has no managers", stream_content("flash", action: "update").text
  end

  test "only administrators set managers" do
    sign_out :user
    sign_in person("editor", role: "editor")

    post admin_group_managers_path(@group), params: { user_id: @ada.id }

    assert_redirected_to root_path
    assert_not GroupManager.exists?(user: @ada)
  end

  test "the card warns that a self-joinable group's manager sees whoever joins, and Global has none" do
    get admin_group_path(@group)
    assert_select "#group-managers", text: /People can join this group themselves/
    assert_select "#group-managers input[name=q]#group-manager-q"

    locked = Group.create!(name: "Managers Locked #{@tag}", admins_add_members: true)
    get admin_group_path(locked)
    assert_select "#group-managers"
    assert_select "#group-managers", text: /People can join this group themselves/, count: 0

    get admin_group_path(global_group)
    assert_select "#group-managers", 0
  end

  test "a person's page names the groups they manage and links to their calls" do
    GroupManager.create!(user: @ada, group: @group)
    Scenario.create!(workflow: Workflow.create!(title: "Managers Flow #{@tag}", user: @admin), user: @ada,
                     purpose: "live", status: "completed", outcome: "resolved", started_at: 1.day.ago,
                     completed_at: 1.day.ago, execution_path: [], results: {}, inputs: {})

    get admin_user_path(@ada)

    assert_select "#user-manages a[href=?]", admin_group_path(@group), text: @group.name
    assert_select "#user-last-active a[href=?]", analytics_agent_path(@ada, range: "all"), text: "View runs"
  end

  private

  def person(label, role: "user", display_name: nil)
    User.create!(email: "managers-#{label}-#{@tag}@example.com", password: "password123!",
                 password_confirmation: "password123!", role:, display_name:)
  end

  # The markup a stream carries. Parsed from the template's inner HTML so the
  # assertion doesn't depend on how the HTML parser treats <template> content.
  def stream_content(target, action:)
    stream = css_select("turbo-stream[action=#{action}][target=#{target}]").first
    assert stream, "no #{action} stream for ##{target}"
    Nokogiri::HTML5.fragment(stream.at_css("template").inner_html)
  end
end
