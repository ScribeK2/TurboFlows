module Workflows
  class PublishingsController < BaseController
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
  end
end
