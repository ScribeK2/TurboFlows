module Workflows
  class VariablesController < BaseController
    before_action :ensure_can_manage_workflows!
    before_action :ensure_can_view_workflow!

    # GET /workflows/:workflow_id/variables
    def show
      variables = @workflow.variables

      render json: { variables: variables }
    end
  end
end
