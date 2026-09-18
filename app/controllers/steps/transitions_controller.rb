module Steps
  # A single connection, acted on from a door row in the step panel. Answers
  # with the step list (row summaries and stubs change) and the panel's
  # Connections section, whole: the editor beside the doors holds a snapshot,
  # and one still listing a removed connection would save it back.
  class TransitionsController < ApplicationController
    include ActionView::RecordIdentifier

    before_action :set_workflow
    before_action :ensure_can_edit!
    before_action :set_step

    # DELETE /workflows/:workflow_id/steps/:step_id/transitions/:id
    def destroy
      @step.transitions.find_by(id: params[:id])&.destroy
      render_connections
    end

    private

    def set_workflow
      @workflow = Workflow.find(params[:workflow_id])
    end

    def set_step
      @step = @workflow.steps.find(params[:step_id])
    end

    def ensure_can_edit!
      return if @workflow.can_be_edited_by?(current_user)

      redirect_to workflows_path, alert: "You don't have permission to edit this workflow."
    end

    def render_connections
      @step.reload
      steps = @workflow.steps.ordered.includes(transitions: :target_step)

      render turbo_stream: [
        turbo_stream.replace("step-list", partial: "workflows/step_list",
                                          locals: { workflow: @workflow, steps: steps }),
        turbo_stream.update(dom_id(@step, :connections), partial: "steps/connections",
                                                         locals: { step: @step, workflow: @workflow })
      ]

      Turbo::StreamsChannel.broadcast_update_to(
        "workflow_#{@workflow.id}",
        target: "steps-list",
        partial: "workflows/steps_list_items",
        locals: { workflow: @workflow, steps: steps }
      )
    end
  end
end
