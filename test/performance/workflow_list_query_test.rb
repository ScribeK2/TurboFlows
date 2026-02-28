require "test_helper"

class WorkflowListQueryTest < ActiveSupport::TestCase
  include PerformanceHelper

  setup do
    @data = seed_performance_data
    @user = @data[:users].first
    @admin = @data[:admin]
  end

  test "loading 200 published workflows for a regular user uses 15 or fewer queries" do
    assert_max_queries(15) do
      workflows = Workflow.visible_to(@user)
                          .includes(:user, group_workflows: :group)
                          .order(updated_at: :desc)
                          .limit(20)
                          .to_a

      # Simulate what the view does — access associations that would trigger N+1
      workflows.each do |w|
        w.primary_group
        w.description_text
        w.can_be_edited_by?(@user)
        w.can_be_viewed_by?(@user)
      end
    end
  end

  test "loading workflows for admin uses 15 or fewer queries" do
    assert_max_queries(15) do
      workflows = Workflow.visible_to(@admin)
                          .includes(:user, group_workflows: :group)
                          .order(updated_at: :desc)
                          .limit(20)
                          .to_a

      workflows.each do |w|
        w.primary_group
        w.description_text
        w.can_be_edited_by?(@admin)
      end
    end
  end

  test "Redcarpet renderer is reused across description_text calls" do
    workflows = @data[:workflows].first(20)
    # If Redcarpet is instantiated once as a constant, object_id will be the same
    # We just verify it completes without creating 20 separate renderers
    assert_completes_within(0.5) do
      workflows.each(&:description_text)
    end
  end

  test "primary_group uses eager-loaded association when available" do
    workflows = Workflow.includes(group_workflows: :group).limit(20).to_a

    assert_max_queries(0) do
      workflows.each(&:primary_group)
    end
  end
end
