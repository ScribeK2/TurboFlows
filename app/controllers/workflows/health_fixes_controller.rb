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
      when "settle_connections"
        settle_connections(step)
      else
        head :unprocessable_content
        nil
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

    # "This step has no way to reach a Resolve." The cheapest true fix is to wire
    # it to a Resolve that already exists — the fix used to build a new one every
    # time, so a Question and a Resolve with no transition between them became
    # two Resolve steps with the original left stranded, and the workflow passed
    # its error check with a dead step in it.
    def add_resolve_after(step)
      existing = @workflow.steps.where(type: "Steps::Resolve").where.not(id: step.id).ordered.first
      return connect_to(step, existing) if existing

      new_position = step.position + 1

      # Shift positions of steps that come after
      @workflow.steps.where(position: new_position..).update_all("position = position + 1")

      resolve_step = Steps::Resolve.create!(
        workflow: @workflow,
        title: "Resolve",
        position: new_position,
        resolution_type: "success"
      )

      connect_to(step, resolve_step)
    end

    # A default connection sorted above a conditional one catches every answer
    # before the runner reaches it (:shadowed_connection). Every builder write
    # already keeps a default last; an import can still write one first. This
    # adds and removes nothing - it only puts the order back.
    def settle_connections(step)
      Transition.settle_positions(step)

      respond_with_updated_steps
    end

    def connect_to(step, target)
      Transition.create!(step: step, target_step: target, position: step.transitions.count)

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
            ),
            # A fix can add a step, so the toolbar count has to move with it.
            # steps#create streams this; this action did not, which left the
            # toolbar reading "2 steps" above three rows.
            turbo_stream.update("step-count-text", helpers.pluralize(steps.size, "step"))
          ]
        end
        format.html { redirect_to workflow_path(@workflow, edit: true), notice: "Fix applied." }
      end
    end
  end
end
