require "test_helper"

class Api::WorkflowCatalogTest < ActiveSupport::TestCase
  setup do
    @team = Group.create!(name: "Catalog Team #{SecureRandom.hex(2)}")
    @other_team = Group.create!(name: "Catalog Other #{SecureRandom.hex(2)}")
    @editor = make_user("editor", group: @team)
    @other_editor = make_user("editor", group: @other_team)
    @csr = make_user("user", group: @team)
    @admin = make_user("admin")

    @team_published = make_workflow("Refunds", user: @other_editor, status: "published", group: @team)
    @hidden_published = make_workflow("Secret", user: @other_editor, status: "published", group: @other_team)
    @my_draft = make_workflow("My draft", user: @editor, status: "draft")
    @their_draft = make_workflow("Their draft", user: @other_editor, status: "draft")
  end

  teardown { Group.where("name LIKE ?", "Catalog %").destroy_all }

  test "an editor sees what their groups see plus their own drafts, nothing else" do
    ids = catalog(@editor).search.workflows.map(&:id)
    assert_includes ids, @team_published.id
    assert_includes ids, @my_draft.id
    assert_not_includes ids, @hidden_published.id
    assert_not_includes ids, @their_draft.id
  end

  test "a CSR sees published workflows in their groups and no drafts" do
    ids = catalog(@csr).search.workflows.map(&:id)
    assert_equal [@team_published.id], ids & [@team_published.id, @hidden_published.id, @my_draft.id, @their_draft.id]
  end

  test "an admin sees every published workflow and every draft" do
    ids = catalog(@admin).search.workflows.map(&:id)
    assert_empty [@team_published, @hidden_published, @my_draft, @their_draft].map(&:id) - ids
  end

  test "find refuses what search would not list" do
    assert_equal @my_draft, catalog(@editor).find(@my_draft.id)
    assert_raises(ActiveRecord::RecordNotFound) { catalog(@editor).find(@their_draft.id) }
    assert_raises(ActiveRecord::RecordNotFound) { catalog(@editor).find(@hidden_published.id) }
  end

  test "filters: q, status, group" do
    assert_equal [@team_published.id], catalog(@editor).search(q: "refund").workflows.map(&:id)
    assert_equal [@my_draft.id], catalog(@editor).search(status: "draft").workflows.map(&:id)
    assert_equal [@team_published.id], catalog(@editor).search(group: @team.id.to_s).workflows.map(&:id)
  end

  test "q matching a hidden workflow's title returns nothing hidden" do
    marker = "Wombat#{SecureRandom.hex(3)}"
    hidden = make_workflow("#{marker} Hidden", user: @other_editor, status: "published", group: @other_team)

    [@editor, @csr].each do |user|
      ids = catalog(user).search(q: marker).workflows.map(&:id)
      assert_not_includes ids, hidden.id
    end
  end

  test "q matching only a hidden workflow's description returns nothing hidden, and still matches a visible one" do
    marker = "Wombat#{SecureRandom.hex(3)}"
    hidden = Workflow.create!(title: "Plain hidden #{SecureRandom.hex(2)}", user: @other_editor, status: "published",
                              description: "text with #{marker} inside")
    GroupWorkflow.create!(workflow: hidden, group: @other_team, is_primary: true)
    # Positive control, so a search_by change that stops reading descriptions
    # cannot make this test pass vacuously.
    visible = Workflow.create!(title: "Plain visible #{SecureRandom.hex(2)}", user: @other_editor, status: "published",
                               description: "text with #{marker} inside too")
    GroupWorkflow.create!(workflow: visible, group: @team, is_primary: true)

    [@editor, @csr].each do |user|
      ids = catalog(user).search(q: marker).workflows.map(&:id)
      assert_not_includes ids, hidden.id
      assert_includes ids, visible.id
    end
  end

  test "tag naming a tag on a hidden workflow returns nothing hidden, and a visible tagged workflow is returned" do
    tag = Tag.create!(name: "Billing#{SecureRandom.hex(3)}")
    hidden = make_workflow("Zebra #{SecureRandom.hex(2)}", user: @other_editor, status: "published", group: @other_team)
    visible = make_workflow("Zebra #{SecureRandom.hex(2)}", user: @other_editor, status: "published", group: @team)
    Tagging.create!(tag:, workflow: hidden)
    Tagging.create!(tag:, workflow: visible)

    [@editor, @csr].each do |user|
      ids = catalog(user).search(tag: tag.name).workflows.map(&:id)
      assert_not_includes ids, hidden.id
      assert_includes ids, visible.id
    end
  end

  test "group of a group the user can't reach returns nothing hidden" do
    hidden = make_workflow("Zebra #{SecureRandom.hex(2)}", user: @other_editor, status: "published", group: @other_team)

    [@editor, @csr].each do |user|
      ids = catalog(user).search(group: @other_team.id.to_s).workflows.map(&:id)
      assert_not_includes ids, hidden.id
    end
  end

  test "q, tag and group combined never widen past what status alone would show" do
    marker = "Wombat#{SecureRandom.hex(3)}"
    tag = Tag.create!(name: "Combo#{SecureRandom.hex(3)}")
    hidden = Workflow.create!(title: "#{marker} Hidden", user: @other_editor, status: "published")
    GroupWorkflow.create!(workflow: hidden, group: @other_team, is_primary: true)
    Tagging.create!(tag:, workflow: hidden)

    [@editor, @csr].each do |user|
      ids = catalog(user).search(q: marker, tag: tag.name, group: @other_team.id.to_s, status: "published")
                         .workflows.map(&:id)
      assert_empty ids
    end
  end

  test "the tag filter matches case-insensitively, like tag uniqueness does" do
    tag = Tag.create!(name: "Billing#{SecureRandom.hex(3)}")
    Tagging.create!(tag:, workflow: @team_published)

    assert_equal [@team_published.id], catalog(@editor).search(tag: tag.name.downcase).workflows.map(&:id)
  end

  test "an unknown status or group is refused, not ignored" do
    assert_raises(Api::WorkflowCatalog::InvalidFilter) { catalog(@editor).search(status: "archived") }
    assert_raises(Api::WorkflowCatalog::InvalidFilter) { catalog(@editor).search(group: "999999") }
  end

  test "garbage page numbers read as page 1, and next_page appears only when there is more" do
    %w[abc 0 -3].each do |page|
      assert_equal catalog(@admin).search.workflows, catalog(@admin).search(page:).workflows
    end
    (Api::WorkflowCatalog::PER_PAGE + 1).times { make_workflow("Bulk #{it}", user: @editor, status: "draft") }
    first = catalog(@editor).search(status: "draft")
    assert_equal Api::WorkflowCatalog::PER_PAGE, first.workflows.size
    assert_equal 2, first.next_page
    assert_nil catalog(@editor).search(status: "draft", page: 2).next_page
  end

  test "an enormous page number is clamped, not sent to the database as an OFFSET" do
    assert_empty catalog(@admin).search(page: "99999999999999999999").workflows
  end

  test "summary carries what an AI needs to choose, and a builder url" do
    summary = catalog(@editor).summary(@team_published)
    assert_equal %i[id title description status tags groups updated_at url].sort, summary.keys.sort
    assert_equal "http://example.test/workflows/#{@team_published.id}", summary[:url]
    assert_equal [@team.name_path], summary[:groups]
  end

  private

  def catalog(user) = Api::WorkflowCatalog.new(user, base_url: "http://example.test")

  def make_user(role, group: nil)
    user = User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                        password_confirmation: "password123!", role: role)
    UserGroup.create!(user:, group:) if group
    user
  end

  def make_workflow(title, user:, status:, group: nil)
    workflow = Workflow.create!(title: "#{title} #{SecureRandom.hex(2)}", user:, status:)
    GroupWorkflow.create!(workflow:, group:, is_primary: true) if group
    workflow
  end
end
