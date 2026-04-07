module Workflows
  class SettingsController < BaseController
    before_action :ensure_can_manage_workflows!
    before_action :ensure_can_view_workflow!

    # GET /workflows/:workflow_id/settings
    def show
      @accessible_groups = Group.visible_to(current_user).includes(:children).order(:name)
      readonly = !@workflow.can_be_edited_by?(current_user)
      render partial: "workflows/settings_panel",
             locals: { workflow: @workflow, readonly: readonly, accessible_groups: @accessible_groups },
             layout: false
    end
  end
end
