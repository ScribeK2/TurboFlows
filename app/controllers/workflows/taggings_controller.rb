module Workflows
  class TaggingsController < BaseController
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

    def require_tag_management!
      head :forbidden unless current_user.can_manage_tags?
    end
  end
end
