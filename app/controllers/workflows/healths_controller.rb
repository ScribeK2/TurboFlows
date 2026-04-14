module Workflows
  class HealthsController < BaseController
    before_action :ensure_can_view_workflow!

    # GET /workflows/:workflow_id/health.json
    # GET /workflows/:workflow_id/health (HTML — Wave 2)
    def show
      @health = WorkflowHealthCheck.call(@workflow)

      respond_to do |format|
        format.json { render json: health_json }
      end
    end

    private

    # Skip rich text preloading — health check only needs transitions + target_step.
    def eager_load_steps
      @workflow.steps.includes(transitions: :target_step).to_a
    end

    def health_json
      {
        issues: @health.issues,
        summary: @health.summary,
        clean: @health.clean?
      }
    end
  end
end
