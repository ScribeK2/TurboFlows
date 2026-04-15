module Workflows
  class HealthFixesController < BaseController
    before_action :ensure_can_edit_workflow!

    # POST /workflows/:workflow_id/health_fix
    def create
      fix_type = params[:fix_type]
      step_uuid = params[:step_uuid]

      step = @workflow.steps.find_by!(uuid: step_uuid)

      case fix_type
      when "connect_next"
        connect_to_next_step(step)
      when "add_resolve_after"
        add_resolve_after(step)
      else
        head :unprocessable_entity
        return
      end
    rescue ActiveRecord::RecordNotFound
      head :not_found
    rescue ActiveRecord::RecordInvalid => e
      redirect_to workflow_path(@workflow, edit: true), alert: e.message
    end

    private

    def connect_to_next_step(step)
      next_step = @workflow.steps.ordered.where("position > ?", step.position).first

      unless next_step
        redirect_to workflow_path(@workflow, edit: true), alert: "No next step to connect to."
        return
      end

      Transition.create!(step: step, target_step: next_step, position: step.transitions.count)

      respond_with_updated_steps
    end

    def add_resolve_after(step)
      new_position = step.position + 1

      # Shift positions of steps that come after
      @workflow.steps.where("position >= ?", new_position).update_all("position = position + 1") # rubocop:disable Rails/SkipsModelValidations

      resolve_step = Steps::Resolve.create!(
        workflow: @workflow,
        title: "Resolve",
        position: new_position,
        resolution_type: "success"
      )

      Transition.create!(step: step, target_step: resolve_step, position: step.transitions.count)

      respond_with_updated_steps
    end

    def respond_with_updated_steps
      @workflow.reload
      steps = @workflow.steps.includes(transitions: :target_step).ordered
      health = WorkflowHealthCheck.call(@workflow)

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "step-list",
              partial: "workflows/step_list",
              locals: { workflow: @workflow, steps: }
            ),
            turbo_stream.update(
              "builder-panel",
              partial: "workflows/health_panel_inner",
              locals: { workflow: @workflow, health: }
            )
          ]
        end
        format.html { redirect_to workflow_path(@workflow, edit: true), notice: "Fix applied." }
      end
    end
  end
end
