class WorkflowVersionsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_workflow
  before_action :set_version, only: [:show, :restore]
  before_action :set_diff_versions, only: [:diff]
  before_action :ensure_can_view_workflow!

  def show
  end

  def diff
    @diff = VersionDiffService.call(
      @version_old.steps_snapshot,
      @version_new.steps_snapshot,
      old_metadata: @version_old.metadata_snapshot,
      new_metadata: @version_new.metadata_snapshot
    )
  end

  def restore
    unless @workflow.can_be_edited_by?(current_user)
      redirect_to @workflow, alert: "You don't have permission to restore versions."
      return
    end

    Workflow.transaction do
      # Use update_column to skip validation during restore — steps are about to be
      # replaced from the snapshot, so validating the intermediate state would fail.
      @workflow.update_columns(graph_mode: @version.metadata_snapshot["graph_mode"] || false)
      restore_ar_steps_from_snapshot(@version.steps_snapshot, @version.metadata_snapshot["start_node_uuid"])
    end

    redirect_to edit_workflow_path(@workflow), notice: "Restored version #{@version.version_number}."
  end

  private

  def set_workflow
    @workflow = Workflow.find(params[:workflow_id])
  end

  def set_version
    @version = @workflow.versions.find(params[:id])
  end

  def restore_ar_steps_from_snapshot(steps_snapshot, start_node_uuid)
    StepBuilder.call(@workflow, steps_snapshot, start_node_uuid: start_node_uuid, replace: true)
  end

  def set_diff_versions
    if params[:v1].blank? || params[:v2].blank?
      redirect_to workflow_versions_path(@workflow), alert: "Select two versions to compare."
      return
    end

    @version_old = @workflow.versions.find(params[:v1])
    @version_new = @workflow.versions.find(params[:v2])
  end

  def ensure_can_view_workflow!
    unless @workflow.can_be_viewed_by?(current_user)
      redirect_to workflows_path, alert: "You don't have permission to view this workflow."
    end
  end
end
