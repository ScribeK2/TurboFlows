module Workflows
  class ExecutionsController < BaseController
    before_action :ensure_can_manage_workflows!
    before_action :ensure_can_view_workflow!

    # GET /workflows/:workflow_id/execution/new
    def new
      render "workflows/start"
    end

    # POST /workflows/:workflow_id/execution
    def create
      @scenario = Scenario.new(
        workflow: @workflow,
        user: current_user,
        current_step_index: 0,
        current_node_uuid: @workflow.start_node&.uuid,
        execution_path: [],
        results: {},
        inputs: {},
        status: 'active'
      )

      if @scenario.save
        redirect_to step_scenario_path(@scenario), notice: "Workflow started!"
      else
        redirect_to new_workflow_execution_path(@workflow), alert: "Failed to start workflow: #{@scenario.errors.full_messages.join(', ')}"
      end
    end
  end
end
