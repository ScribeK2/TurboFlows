module Workflows
  class FlowDiagramsController < BaseController
    before_action :ensure_can_manage_workflows!
    before_action :ensure_can_view_workflow!

    # GET /workflows/:workflow_id/flow_diagram
    def show
      levels = FlowDiagramService.call(@workflow)
      render partial: "workflows/flow_diagram_panel",
             locals: { workflow: @workflow, levels: levels },
             layout: false
    end
  end
end
