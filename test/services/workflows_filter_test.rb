require "test_helper"

class WorkflowsFilterTest < ActiveSupport::TestCase
  setup do
    @admin = User.create!(
      email: "wf-filter-admin-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    @editor = User.create!(
      email: "wf-filter-editor-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @published_wf = Workflow.create!(title: "Published Alpha", user: @editor, status: "published", is_public: true)
    @draft_wf = Workflow.create!(title: "Draft Beta", user: @editor, status: "draft")
    @other_wf = Workflow.create!(title: "Other Gamma", user: @admin, status: "published", is_public: true)
  end

  test "default scope returns published plus own drafts for editor" do
    filter = WorkflowsFilter.new(user: @editor, params: {}).call
    ids = filter.workflows.pluck(:id)
    assert_includes ids, @published_wf.id
    assert_includes ids, @draft_wf.id
    assert_includes ids, @other_wf.id
  end

  test "status filter draft returns only users drafts" do
    filter = WorkflowsFilter.new(user: @editor, params: { status: "draft" }).call
    ids = filter.workflows.pluck(:id)
    assert_includes ids, @draft_wf.id
    assert_not_includes ids, @published_wf.id
  end

  test "status filter published returns visible workflows" do
    filter = WorkflowsFilter.new(user: @editor, params: { status: "published" }).call
    ids = filter.workflows.pluck(:id)
    assert_includes ids, @published_wf.id
    assert_includes ids, @other_wf.id
    assert_not_includes ids, @draft_wf.id
  end

  test "search filters by query" do
    filter = WorkflowsFilter.new(user: @admin, params: { search: "Alpha" }).call
    titles = filter.workflows.pluck(:title)
    assert_includes titles, "Published Alpha"
    assert_not_includes titles, "Draft Beta"
  end

  test "sort by alphabetical orders by title" do
    filter = WorkflowsFilter.new(user: @admin, params: { sort: "alphabetical" }).call
    titles = filter.workflows_paginated.pluck(:title)
    assert_equal titles, titles.sort_by(&:downcase)
  end

  test "sort by most_steps orders by steps_count desc" do
    Steps::Action.create!(workflow: @published_wf, position: 0, title: "S1")
    Steps::Action.create!(workflow: @published_wf, position: 1, title: "S2")
    @published_wf.reload
    filter = WorkflowsFilter.new(user: @admin, params: { sort: "most_steps" }).call
    counts = filter.workflows_paginated.map(&:steps_count)
    assert_operator counts.first, :>=, counts.last, "Expected descending step count order"
  end

  test "sort default recent orders by updated_at desc" do
    @draft_wf.touch
    filter = WorkflowsFilter.new(user: @editor, params: {}).call
    ids = filter.workflows_paginated.pluck(:id)
    assert_equal @draft_wf.id, ids.first
  end

  test "group filter restricts to selected group" do
    group = Group.create!(name: "Filter Group #{SecureRandom.hex(4)}")
    GroupWorkflow.create!(group: group, workflow: @published_wf)
    UserGroup.create!(user: @editor, group: group)
    filter = WorkflowsFilter.new(user: @editor, params: { group_id: group.id }).call
    assert_equal group, filter.selected_group
    assert_includes filter.workflows.pluck(:id), @published_wf.id
  end

  test "group filter sets error for inaccessible group" do
    private_group = Group.create!(name: "Private Group #{SecureRandom.hex(4)}")
    filter = WorkflowsFilter.new(user: @editor, params: { group_id: private_group.id }).call
    assert_equal "You don't have permission to view this group.", filter.group_error
  end

  test "pagination calculates pages and limits results" do
    12.times { |i| Workflow.create!(title: "Paginated #{i}", user: @admin, status: "published", is_public: true) }
    filter = WorkflowsFilter.new(user: @admin, params: { page: "2" }).call
    assert_equal 2, filter.page
    assert_operator filter.total_pages, :>=, 2
    assert_operator filter.workflows_paginated.size, :<=, WorkflowsFilter::PER_PAGE
  end
end
