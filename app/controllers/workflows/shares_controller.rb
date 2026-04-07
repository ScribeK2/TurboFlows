module Workflows
  class SharesController < BaseController
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
  end
end
