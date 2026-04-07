module Workflows
  class VersionsController < BaseController
    before_action :ensure_can_manage_workflows!
    before_action :ensure_can_view_workflow!

    # GET /workflows/:workflow_id/versions
    def index
      @versions = @workflow.versions.newest_first.includes(:published_by)
      render "workflows/versions"
    end
  end
end
