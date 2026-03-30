class DashboardController < ApplicationController
  def index
    # Workflow counts
    @workflow_count = Workflow.visible_to(current_user).count
    @published_count = @workflow_count

    # Draft count (editors/admins only - regular users can't create workflows)
    @draft_count = current_user.can_create_workflows? ? current_user.workflows.drafts.count : 0

    # Recent workflows: for editors/admins, include their own drafts alongside published
    if current_user.can_create_workflows?
      visible_ids = Workflow.visible_to(current_user).select(:id)
      draft_ids = current_user.workflows.drafts.select(:id)
      @workflows = Workflow.where(id: visible_ids).or(Workflow.where(id: draft_ids))
                           .includes(:tags).order(created_at: :desc).limit(5)
    else
      @workflows = Workflow.visible_to(current_user).includes(:tags).recent.limit(5)
    end

    # Scenario stats (scoped to current user)
    user_scenarios = Scenario.where(user: current_user)
    @scenario_total = user_scenarios.count
    @scenario_completed = user_scenarios.where(status: "completed").count
    @scenario_active = user_scenarios.where(status: "active").count
    @scenario_completion_rate = @scenario_total > 0 ? ((@scenario_completed * 100.0) / @scenario_total).round : 0

    # Recent scenarios (last 5, eager-load workflow to avoid N+1)
    @recent_scenarios = user_scenarios.includes(:workflow)
                                          .order(created_at: :desc)
                                          .limit(5)
  end
end
