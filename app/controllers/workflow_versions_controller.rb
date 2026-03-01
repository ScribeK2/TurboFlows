class WorkflowVersionsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_workflow
  before_action :set_version, only: [:show, :restore]

  def show
  end

  def restore
    unless @workflow.can_be_edited_by?(current_user)
      redirect_to @workflow, alert: "You don't have permission to restore versions."
      return
    end

    @workflow.update!(
      steps: @version.steps_snapshot.deep_dup,
      graph_mode: @version.metadata_snapshot["graph_mode"] || false,
      start_node_uuid: @version.metadata_snapshot["start_node_uuid"]
    )

    redirect_to edit_workflow_path(@workflow), notice: "Restored version #{@version.version_number}."
  end

  private

  def set_workflow
    @workflow = Workflow.find(params[:workflow_id])
  end

  def set_version
    @version = @workflow.versions.find(params[:id])
  end
end
