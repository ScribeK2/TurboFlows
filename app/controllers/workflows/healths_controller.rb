module Workflows
  class HealthsController < BaseController
    before_action :ensure_can_view_workflow!

    # GET /workflows/:workflow_id/health.json  — JS health fetch (Wave 1)
    # GET /workflows/:workflow_id/health       — panel view (Wave 2)
    def show
      @health = WorkflowHealthCheck.call(@workflow)

      respond_to do |format|
        format.html do
          render partial: "workflows/health_panel",
                 locals: { workflow: @workflow, health: @health },
                 layout: false
        end
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
