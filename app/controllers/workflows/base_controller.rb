module Workflows
  class BaseController < ApplicationController
    before_action :set_workflow

    private

    def set_workflow
      @workflow = Workflow.find(params[:workflow_id])
      eager_load_steps
      preload_subflow_targets
    end

    # Eager load steps with rich text associations and transitions to prevent N+1 queries.
    # Rich text associations are defined on specific STI subclasses, so we preload per-type.
    def eager_load_steps
      steps = @workflow.steps.includes(transitions: :target_step).to_a

      { rich_text_instructions: Steps::Action,
        rich_text_content: Steps::Message,
        rich_text_notes: Steps::Escalate }.each do |assoc, klass|
        typed = steps.grep(klass)
        next if typed.empty?

        ActiveRecord::Associations::Preloader.new(records: typed, associations: [assoc]).call
      end
    end

    # Preload all workflows referenced by sub-flow steps to avoid N+1 queries in partials
    def preload_subflow_targets
      subflow_ids = Steps::SubFlow.where(workflow_id: @workflow.id).pluck(:sub_flow_workflow_id).compact
      @subflow_targets = Workflow.where(id: subflow_ids).index_by(&:id) if subflow_ids.any?
    end

    def ensure_can_view_workflow!
      unless @workflow.can_be_viewed_by?(current_user)
        redirect_to workflows_path, alert: "You don't have permission to view this workflow."
      end
    end

    def ensure_can_edit_workflow!
      unless @workflow.can_be_edited_by?(current_user)
        redirect_to workflows_path, alert: "You don't have permission to edit this workflow."
      end
    end
  end
end
