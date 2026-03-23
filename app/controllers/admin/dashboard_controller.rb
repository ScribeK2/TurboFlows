class Admin::DashboardController < Admin::BaseController
  def index
    @users_count = User.count
    @workflows_count = Workflow.count
    @public_workflows_count = Workflow.where(is_public: true).count

    @recent_users = User.order(created_at: :desc).limit(5)
    @recent_workflows = Workflow.order(created_at: :desc).limit(5)
  end
end
