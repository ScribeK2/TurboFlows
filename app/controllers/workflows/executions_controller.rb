module Workflows
  class ExecutionsController < BaseController
    before_action :ensure_can_manage_workflows!
    before_action :ensure_can_view_workflow!

    # GET used to render a landing page. Turbo prefetches GET links, so this
    # must not start a run. Leftover bookmarks land on the workflow instead.
    def new
      redirect_to workflow_path(@workflow)
    end

    # POST /workflows/:workflow_id/execution
    def create
      redirect_to step_scenario_path(Scenario.start!(@workflow, user: current_user, purpose: "simulation"))
    rescue ActiveRecord::RecordInvalid => e
      redirect_to workflow_path(@workflow), alert: "Failed to start workflow: #{e.record.errors.full_messages.join(', ')}"
    end
  end
end
