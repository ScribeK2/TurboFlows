module Workflows
  class PinsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_workflow

    # POST /workflows/:workflow_id/pin
    def create
      pin = current_user.user_workflow_pins.new(workflow: @workflow)

      if pin.save
        respond_to do |format|
          format.turbo_stream { render_pin_updates(pinned: true) }
          format.html { redirect_back_or_to workflows_path }
        end
      else
        redirect_back_or_to workflows_path, alert: pin.errors.full_messages.first
      end
    end

    # DELETE /workflows/:workflow_id/pin
    def destroy
      pin = current_user.user_workflow_pins.find_by!(workflow: @workflow)
      pin.destroy

      respond_to do |format|
        format.turbo_stream { render_pin_updates(pinned: false) }
        format.html { redirect_back_or_to workflows_path }
      end
    end

    private

    def set_workflow
      @workflow = Workflow.visible_to(current_user).find(params[:workflow_id])
    end

    def render_pin_updates(pinned:)
      dashboard = Dashboard::DataLoader.new(current_user)

      render turbo_stream: [
        turbo_stream.replace("pinned-workflows-section",
                             partial: "dashboard/pinned_workflows",
                             locals: { dashboard: dashboard }),
        turbo_stream.replace("pin-recent-#{@workflow.id}",
                             partial: "workflows/pin_button",
                             locals: { workflow: @workflow, pinned: pinned, location: "recent" })
      ]
    end
  end
end
