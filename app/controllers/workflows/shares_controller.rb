module Workflows
  class SharesController < ApplicationController
    before_action :authenticate_user!
    before_action :set_workflow
    before_action :ensure_can_edit_workflow!

    # POST /workflows/:workflow_id/share
    def create
      @workflow.generate_share_token!
      redirect_to @workflow, notice: "Share link generated."
    end

    # DELETE /workflows/:workflow_id/share
    def destroy
      @workflow.revoke_share_token!
      redirect_to @workflow, notice: "Share link revoked."
    end

    private

    def set_workflow
      @workflow = Workflow.find(params[:workflow_id])
    end

    def ensure_can_edit_workflow!
      unless @workflow.can_be_edited_by?(current_user)
        head :forbidden
      end
    end
  end
end
