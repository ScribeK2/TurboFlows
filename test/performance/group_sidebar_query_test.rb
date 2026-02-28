require "test_helper"

class GroupSidebarQueryTest < ActiveSupport::TestCase
  include PerformanceHelper

  setup do
    @data = seed_performance_data
    @user = @data[:users].first
  end

  test "workflows_count for 30 groups with descendants uses 5 or fewer queries" do
    groups = Group.all.to_a # load all 30 groups

    assert_max_queries(5) do
      Group.precompute_workflows_counts(groups)
      groups.each do |g|
        g.workflows_count(include_descendants: true)
      end
    end
  end

  test "ancestors for a depth-3 group uses bounded queries" do
    # Find a level 3 group (deepest in our hierarchy)
    deep_group = @data[:groups].detect { |g| g.parent&.parent.present? }
    skip("No depth-3 group found in seed data") unless deep_group

    # SQLite: N queries for N levels + 1 bulk load (max depth=5 => max 6 queries)
    # PostgreSQL: 1 CTE query + 1 bulk load = 2 queries
    assert_max_queries(6) do
      deep_group.ancestors
    end
  end

  test "sidebar group rendering simulation uses bounded queries" do
    root_groups = Group.where(parent_id: nil).includes(:children).order(:position, :name).to_a
    all_sidebar_groups = root_groups + root_groups.flat_map(&:children)

    # Simulate what the sidebar partial does for each group
    assert_max_queries(10) do
      Group.precompute_workflows_counts(all_sidebar_groups)
      root_groups.each do |group|
        group.workflows_count(include_descendants: true)
        group.children.each do |child|
          child.workflows_count(include_descendants: true)
        end
      end
    end
  end
end
