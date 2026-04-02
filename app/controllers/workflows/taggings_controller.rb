module Workflows
  class TaggingsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_workflow
    before_action :require_tag_management!

    # POST /workflows/:workflow_id/taggings
    def create
      tag = Tag.find(params[:tag_id])
      @workflow.tags << tag unless @workflow.tags.include?(tag)
      render turbo_stream: turbo_stream.replace("workflow-tags", partial: "tags/tag_selector", locals: { workflow: @workflow })
    end

    # DELETE /workflows/:workflow_id/taggings/:id
    def destroy
      tag = Tag.find(params[:tag_id])
      @workflow.tags.delete(tag)
      render turbo_stream: turbo_stream.replace("workflow-tags", partial: "tags/tag_selector", locals: { workflow: @workflow })
    end

    private

    def set_workflow
      @workflow = Workflow.find(params[:workflow_id])
    end

    def require_tag_management!
      head :forbidden unless current_user.can_manage_tags?
    end
  end
end
