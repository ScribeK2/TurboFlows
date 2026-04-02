module Workflows
  class PublishingsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_workflow
    before_action :ensure_can_edit_workflow!

    # POST /workflows/:workflow_id/publishing
    def create
      result = WorkflowPublisher.publish(@workflow, current_user, changelog: params[:changelog])

      if result.success?
        redirect_to @workflow, notice: "Workflow published as version #{result.version.version_number}."
      else
        redirect_to @workflow, alert: "Failed to publish: #{result.error}"
      end
    end

    private

    def set_workflow
      @workflow = Workflow.find(params[:workflow_id])
    end

    def ensure_can_edit_workflow!
      unless @workflow.can_be_edited_by?(current_user)
        redirect_to workflows_path, alert: "You don't have permission to edit this workflow."
      end
    end
  end
end
