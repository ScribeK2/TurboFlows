require "test_helper"

# The Editor and Admin home page's data (spec docs/designs/2026-09-12-editor-admin-home.md).
class Dashboard::HomeTest < ActiveSupport::TestCase
  setup do
    @editor = User.create!(email: "home-editor-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @admin = User.create!(email: "home-admin-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                          password_confirmation: "password123!", role: "admin")
  end

  test "the hero is your most recently edited workflow that has a step" do
    older = workflow_with_step("Older", user: @editor, edited_at: 2.days.ago)
    newer = workflow_with_step("Newer", user: @editor, edited_at: 1.hour.ago)
    Workflow.create!(title: "Untitled Workflow", user: @editor, status: "draft") # empty, edited just now

    home = Dashboard::Home.new(@editor)

    assert_equal newer, home.hero.first
    assert_equal [older], home.also_recent.map(&:first)
  end

  test "someone else's workflow is never an editor's hero" do
    mine = workflow_with_step("Mine", user: @editor, edited_at: 3.days.ago)
    workflow_with_step("Theirs", user: @admin, edited_at: 1.minute.ago)

    home = Dashboard::Home.new(@editor)

    assert_equal mine, home.hero.first
    assert_not home.showing_library?
  end

  test "an editor with nothing has no hero and never gets the library" do
    workflow_with_step("Theirs", user: @admin)

    home = Dashboard::Home.new(@editor)

    assert_nil home.hero
    assert_empty home.also_recent
    assert_not home.showing_library?
  end

  test "an admin who has built nothing sees the library's recent edits" do
    theirs = workflow_with_step("Editor's work", user: @editor, edited_at: Time.current)

    home = Dashboard::Home.new(@admin)

    assert_predicate home, :showing_library?
    assert_equal theirs, home.hero.first
  end

  test "an admin with a workflow of their own does not see the library" do
    own = workflow_with_step("Admin's own", user: @admin, edited_at: 3.days.ago)
    workflow_with_step("Editor's newer", user: @editor, edited_at: 1.hour.ago)

    home = Dashboard::Home.new(@admin)

    assert_not home.showing_library?
    assert_equal own, home.hero.first
  end

  test "a draft hero lists what blocks its publish" do
    workflow_with_step("Draft, no audience", user: @editor)

    assert_equal [:no_audience], Dashboard::Home.new(@editor).hero_blockers.pluck(:code)
  end

  test "a published hero is not checked at all" do
    file_in_global(workflow_with_step("Live", user: @editor, status: "published"))
    home = Dashboard::Home.new(@editor)
    home.hero

    queries = count_queries { assert_nil home.hero_blockers }

    assert_equal 0, queries, "a published hero must not run WorkflowHealthCheck"
  end

  test "drafts with steps are counted, and the five most recently edited are named" do
    7.times { |i| workflow_with_step("Draft #{i}", user: @editor, edited_at: i.hours.ago) }
    Workflow.create!(title: "Untitled Workflow", user: @editor, status: "draft")
    file_in_global(workflow_with_step("Published", user: @editor, status: "published"))

    home = Dashboard::Home.new(@editor)

    assert_equal 7, home.draft_count
    assert_equal ["Draft 0", "Draft 1", "Draft 2", "Draft 3", "Draft 4"], home.named_drafts.map(&:title)
  end

  test "an editor's published workflows with no audience are named" do
    hidden = workflow_with_step("Nobody sees", user: @editor, status: "published")
    file_in_global(workflow_with_step("Everyone sees", user: @editor, status: "published"))

    home = Dashboard::Home.new(@editor)

    assert_equal 1, home.no_audience_count
    assert_equal [hidden], home.named_no_audience
    assert_predicate home, :waiting?
  end

  test "an admin gets no no-audience row, because the attention strip counts every one" do
    workflow_with_step("Admin's hidden", user: @admin, status: "published")

    home = Dashboard::Home.new(@admin)

    assert_equal 0, home.no_audience_count
    assert_empty home.named_no_audience
  end

  test "nothing is waiting when every workflow is published with an audience" do
    file_in_global(workflow_with_step("Live", user: @editor, status: "published"))

    assert_not Dashboard::Home.new(@editor).waiting?
  end

  test "attention is for admins only" do
    assert_nil Dashboard::Home.new(@editor).attention
    assert_instance_of Admin::Attention, Dashboard::Home.new(@admin).attention
  end

  private

  def workflow_with_step(title, user:, status: "draft", edited_at: Time.current)
    workflow = Workflow.create!(title:, user:, status:)
    step = Steps::Resolve.create!(workflow:, position: 0, title: "Done", resolution_type: "success")
    step.update_columns(updated_at: edited_at)
    workflow.update_columns(updated_at: edited_at)
    workflow
  end
end
