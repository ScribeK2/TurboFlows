module Workflows
  class StepSyncsController < BaseController
    before_action :ensure_can_manage_workflows!
    before_action :ensure_can_edit_workflow!

    # PATCH /workflows/:workflow_id/step_sync
    def update
      client_lock_version = params[:lock_version].to_i

      if client_lock_version > 0 && @workflow.lock_version != client_lock_version
        render json: { error: "This workflow was modified by another user. Please refresh and try again." },
               status: :conflict
        return
      end

      result = StepSyncer.call(
        @workflow,
        params[:steps] || [],
        start_node_uuid: params[:start_node_uuid],
        title: params[:title].presence,
        description: params.key?(:description) ? params[:description] : nil
      )

      if result.success?
        render json: { success: true, lock_version: result.lock_version }
      else
        render json: { error: result.error }, status: :unprocessable_content
      end
    end
  end
end
