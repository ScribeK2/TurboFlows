require "test_helper"

module Admin
  class WorkflowsFilterTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "admin-wf-filter-#{SecureRandom.hex(4)}@test.com", password: "password123456")
      @workflows = Array.new(12) { |i| Workflow.create!(title: "Filter WF #{i}", user: @user) }
      @scope = Workflow.where(user: @user)
    end

    # ---------------------------------------------------------------------------
    # Default pagination
    # ---------------------------------------------------------------------------

    test "defaults to page 1 with 10 per page" do
      filter = Admin::WorkflowsFilter.new(params: {}, scope: @scope).call

      assert_equal 1, filter.current_page
      assert_equal 10, filter.per_page_size
      assert_equal 10, filter.workflows.size
      assert_equal 12, filter.total_count
      assert_equal 2, filter.total_pages
    end

    # ---------------------------------------------------------------------------
    # Page navigation
    # ---------------------------------------------------------------------------

    test "page 2 returns remaining workflows" do
      filter = Admin::WorkflowsFilter.new(params: { page: "2" }, scope: @scope).call

      assert_equal 2, filter.current_page
      assert_equal 2, filter.workflows.size
    end

    test "page 0 or negative is clamped to 1" do
      filter_zero = Admin::WorkflowsFilter.new(params: { page: "0" }, scope: @scope).call
      filter_neg  = Admin::WorkflowsFilter.new(params: { page: "-5" }, scope: @scope).call

      assert_equal 1, filter_zero.current_page
      assert_equal 1, filter_neg.current_page
    end

    test "page beyond total_pages is clamped to last page" do
      filter = Admin::WorkflowsFilter.new(params: { page: "999" }, scope: @scope).call

      assert_equal 2, filter.current_page
      assert_equal 2, filter.workflows.size
    end

    # ---------------------------------------------------------------------------
    # Per page options
    # ---------------------------------------------------------------------------

    test "per_page accepts valid options (10, 25, 50)" do
      filter_twenty_five = Admin::WorkflowsFilter.new(params: { per_page: "25" }, scope: @scope).call
      assert_equal 25, filter_twenty_five.per_page_size
      assert_equal 12, filter_twenty_five.workflows.size

      filter_fifty = Admin::WorkflowsFilter.new(params: { per_page: "50" }, scope: @scope).call
      assert_equal 50, filter_fifty.per_page_size
    end

    test "invalid per_page falls back to default" do
      filter = Admin::WorkflowsFilter.new(params: { per_page: "15" }, scope: @scope).call
      assert_equal 10, filter.per_page_size

      filter_zero = Admin::WorkflowsFilter.new(params: { per_page: "0" }, scope: @scope).call
      assert_equal 10, filter_zero.per_page_size
    end

    # ---------------------------------------------------------------------------
    # Ordering
    # ---------------------------------------------------------------------------

    test "results are ordered by created_at descending" do
      filter = Admin::WorkflowsFilter.new(params: { per_page: "50" }, scope: @scope).call
      dates = filter.workflows.map(&:created_at)

      assert_equal dates, dates.sort.reverse
    end

    # ---------------------------------------------------------------------------
    # Custom scope
    # ---------------------------------------------------------------------------

    test "accepts custom scope narrower than default" do
      draft = Workflow.create!(title: "Draft Only", user: @user, status: "draft")
      scope = Workflow.where(user: @user, status: "draft")

      filter = Admin::WorkflowsFilter.new(params: {}, scope: scope).call

      assert_equal 1, filter.total_count
      assert_includes filter.workflows, draft
    end

    # ---------------------------------------------------------------------------
    # Edge case: empty results
    # ---------------------------------------------------------------------------

    test "empty scope returns 0 total with 1 total_pages minimum" do
      filter = Admin::WorkflowsFilter.new(params: {}, scope: Workflow.none).call

      assert_equal 0, filter.total_count
      assert_equal 1, filter.total_pages
      assert_empty filter.workflows
    end

    # ---------------------------------------------------------------------------
    # Chainability
    # ---------------------------------------------------------------------------

    test "call returns self for chaining" do
      filter = Admin::WorkflowsFilter.new(params: {}, scope: @scope)
      result = filter.call

      assert_same filter, result
    end
  end
end
