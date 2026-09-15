module Workflows
  class SettingsController < BaseController
    before_action :ensure_can_manage_workflows!
    before_action :ensure_can_view_workflow!

    # GET /workflows/:workflow_id/settings
    def show
      readonly = params[:readonly].present? || !@workflow.can_be_edited_by?(current_user)
      render partial: "workflows/settings_panel",
             locals: { workflow: @workflow, readonly: readonly, group_nodes: group_nodes },
             layout: false
    end

    private

    # Full paths, limited to the groups this person reaches (spec Q38) — an
    # editor in one department should not scroll every department to find it.
    # Groups the workflow is in that they don't reach are kept on save by
    # Group.assignable_ids_for.
    def group_nodes
      return Group.tree_nodes if current_user.admin?

      Group.tree_nodes(within: Group.reachable_ids_for(current_user))
    end
  end
end
