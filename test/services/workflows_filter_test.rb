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
    assert_operator filter.workflows_paginated.size, :<=, WorkflowsFilter::DEFAULT_PER_PAGE
  end

  test "per_page defaults to DEFAULT_PER_PAGE when the param is absent" do
    filter = WorkflowsFilter.new(user: @admin, params: {}).call
    assert_equal WorkflowsFilter::DEFAULT_PER_PAGE, filter.per_page_size
  end

  test "per_page honours every allowlisted option" do
    30.times { |i| Workflow.create!(title: "Sized #{i}", user: @admin, status: "published", is_public: true) }

    WorkflowsFilter::PER_PAGE_OPTIONS.each do |size|
      filter = WorkflowsFilter.new(user: @admin, params: { per_page: size.to_s }).call
      assert_equal size, filter.per_page_size, "expected per_page_size to honour #{size}"
      assert_equal size, filter.workflows_paginated.size, "expected #{size} rows on a full page"
    end
  end

  test "per_page falls back to the default for values off the allowlist" do
    ["7", "0", "-5", "1000", "abc", "", nil].each do |bad|
      filter = WorkflowsFilter.new(user: @admin, params: { per_page: bad }).call
      assert_equal WorkflowsFilter::DEFAULT_PER_PAGE, filter.per_page_size,
                   "expected #{bad.inspect} to fall back to the default page size"
    end
  end

  test "per_page changes how many pages the same result set spans" do
    12.times { |i| Workflow.create!(title: "Spanning #{i}", user: @admin, status: "published", is_public: true) }

    small = WorkflowsFilter.new(user: @admin, params: { per_page: "6" }).call
    large = WorkflowsFilter.new(user: @admin, params: { per_page: "24" }).call

    assert_equal small.total_count, large.total_count, "page size must not change the result count"
    assert_operator small.total_pages, :>, large.total_pages
  end

  test "page is clamped to the last page when a larger size collapses the range" do
    12.times { |i| Workflow.create!(title: "Clamped #{i}", user: @admin, status: "published", is_public: true) }

    filter = WorkflowsFilter.new(user: @admin, params: { page: "3", per_page: "24" }).call

    assert_equal filter.total_pages, filter.page,
                 "asking for page 3 at a size that yields fewer pages must clamp, not return an empty page"
    assert_predicate filter.workflows_paginated, :any?
  end
end
