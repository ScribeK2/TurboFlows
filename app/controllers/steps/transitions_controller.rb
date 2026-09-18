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

    # POST /workflows/:workflow_id/steps/:step_id/transitions
    def create
      GrowStep.connect(workflow: @workflow, from_step: @step, target_step: target_step,
                       label: params[:label], condition: params[:condition])
      render_connections
    rescue GrowStep::Refused => e
      render_refusal(e.message)
    rescue ActiveRecord::RecordInvalid => e
      render_refusal(e.record.errors.full_messages.to_sentence)
    end

    # PATCH /workflows/:workflow_id/steps/:step_id/transitions/:id
    def update
      @step.transitions.find(params[:id]).update!(target_step: target_step)
      render_connections
    rescue ActiveRecord::RecordInvalid => e
      render_refusal(e.record.errors.full_messages.to_sentence)
    end

    # DELETE /workflows/:workflow_id/steps/:step_id/transitions/:id
    def destroy
      @step.transitions.find_by(id: params[:id])&.destroy
      render_connections
    end

    private

    def target_step
      @workflow.steps.find(params.require(:target_step_id))
    end

    def render_refusal(message)
      flash.now[:alert] = "That connection was not saved: #{message}"
      render turbo_stream: turbo_stream.update("flash", partial: "shared/flash_messages"), status: :unprocessable_content
    end

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
                                                         locals: { step: @step, workflow: @workflow }),
        # The dialog's own list is rendered with the panel, so a step grown
        # after it opened is missing until this refreshes it. It also closes
        # the dialog on success once applied - the JS-side close (on
        # turbo:submit-end, gated on success) has already run by then, since
        # that event fires before this stream is applied; this replace keeps
        # the list fresh for the next open rather than fighting that close.
        turbo_stream.replace(dom_id(@step, :target_picker), partial: "steps/target_picker",
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
