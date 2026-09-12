require "test_helper"

class Workflows::OwnerFilterTest < ActionDispatch::IntegrationTest
  setup do
    @editor = User.create!(email: "owner-filter-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    other = User.create!(email: "owner-other-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                         password_confirmation: "password123!", role: "editor")
    @mine = file_in_global(Workflow.create!(title: "Mine #{SecureRandom.hex(3)}", user: @editor))
    @theirs = file_in_global(Workflow.create!(title: "Theirs #{SecureRandom.hex(3)}", user: other))
    sign_in @editor
  end

  test "owner=me lists only your workflows and says so" do
    get workflows_path(owner: "me")

    assert_match @mine.title, response.body
    assert_no_match @theirs.title, response.body
    assert_select ".wf-audience-note", text: /Showing only your workflows/
    assert_select ".wf-audience-note a[href=?]", workflows_path, text: "Show all"
  end

  test "the status tabs, sort, search and sidebar keep owner=me" do
    get workflows_path(owner: "me")

    assert_select ".wf-status-tabs__tab[href*='owner=me']", minimum: 2
    assert_select "select[aria-label='Sort workflows'] option[value*='owner=me']", count: 3
    assert_select "input[type=hidden][name=owner][value=me]"
    assert_select ".group-sidebar__link[href*='owner=me']", minimum: 2
  end

  test "sidebar counts follow the filtered list" do
    get workflows_path(owner: "me")

    assert_select ".group-sidebar__link", text: /#{Group::GLOBAL_NAME}\s+1\b/o
  end

  test "owner=me narrows a group's Unfiled section to your own workflows" do
    group = Group.create!(name: "Owner Filter Group #{SecureRandom.hex(4)}")
    UserGroup.create!(user: @editor, group: group)
    Folder.create!(name: "A Folder", group: group)
    other = User.create!(email: "owner-other2-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                         password_confirmation: "password123!", role: "editor")
    mine_unfiled = Workflow.create!(title: "Mine Unfiled #{SecureRandom.hex(3)}", user: @editor, status: "published")
    their_unfiled = Workflow.create!(title: "Theirs Unfiled #{SecureRandom.hex(3)}", user: other, status: "published")
    GroupWorkflow.create!(group: group, workflow: mine_unfiled, is_primary: true)
    GroupWorkflow.create!(group: group, workflow: their_unfiled, is_primary: true)

    get workflows_path(group_id: group.id, owner: "me")

    assert_match mine_unfiled.title, response.body
    assert_no_match their_unfiled.title, response.body
  end
end
