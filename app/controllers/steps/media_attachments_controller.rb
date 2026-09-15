module Steps
  # Attach and detach a step's media, one file at a time, answering with the
  # panel's attachment list. Attach takes a blob the browser already
  # direct-uploaded, so the step's autosave never carries file bytes.
  # Attaching touches the step and so bumps its lock_version, but the panel
  # never sends lock_version, so this cannot conflict with an autosave.
  class MediaAttachmentsController < ApplicationController
    include ActionView::RecordIdentifier

    before_action :set_workflow
    before_action :ensure_can_edit!
    before_action :set_step

    # POST /workflows/:workflow_id/steps/:step_id/media_attachments
    def create
      blob = ActiveStorage::Blob.find_signed!(params.require(:signed_id))

      # `attach` appends and saves; on a validation failure (type, size) it
      # returns nil with the errors on the step. Plain assignment would replace
      # every existing attachment, which is why this is not `update`.
      if @step.media_attachments.attach(blob)
        render_list
      else
        render_refusal("This file could not be attached: #{@step.errors.full_messages.to_sentence}.")
      end
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
      render_refusal("This file could not be attached. Choose it again.")
    end

    # DELETE /workflows/:workflow_id/steps/:step_id/media_attachments/:id
    def destroy
      @step.media_attachments.attachments.find(params[:id]).purge_later
      render_list
    rescue ActiveRecord::RecordNotFound
      # Already gone (another tab, a double submit): the list is the answer either way.
      render_list
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

    def render_list
      render turbo_stream: turbo_stream.replace(
        dom_id(@step, :media),
        partial: "steps/media_list",
        locals: { step: @step.reload, removable: true }
      )
    end

    def render_refusal(message)
      flash.now[:alert] = message
      render turbo_stream: turbo_stream.update("flash", partial: "shared/flash_messages"),
             status: :unprocessable_content
    end
  end
end
