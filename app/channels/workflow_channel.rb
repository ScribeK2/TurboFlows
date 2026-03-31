class WorkflowChannel < ApplicationCable::Channel
  @memory_presence_store = {}
  @presence_mutex = Mutex.new

  class << self
    attr_reader :memory_presence_store, :presence_mutex
  end

  def subscribed
    workflow = find_workflow

    if workflow.can_be_edited_by?(current_user)
      stream_from "workflow:#{workflow.id}"
      stream_from "workflow:#{workflow.id}:presence"

      WorkflowPresence.track(
        workflow_id: workflow.id,
        user_id: current_user.id,
        user_name: current_user.email.split("@").first.titleize,
        user_email: current_user.email
      )
      broadcast_presence_update(workflow, type: "user_joined", user: user_info)
    else
      reject
    end
  end

  def unsubscribed
    workflow = Workflow.find_by(id: params[:workflow_id])
    if workflow
      WorkflowPresence.untrack(workflow_id: workflow.id, user_id: current_user.id)
      broadcast_presence_update(workflow, type: "user_left", user: user_info)
    end
  end

  def workflow_metadata_update(data)
    workflow = find_workflow
    return unless workflow.can_be_edited_by?(current_user)

    ActionCable.server.broadcast("workflow:#{workflow.id}", {
                                   type: "workflow_metadata_update",
                                   field: data["field"],
                                   value: data["value"],
                                   user: user_info,
                                   timestamp: Time.current.iso8601
                                 })
  end

  private

  def find_workflow
    @find_workflow ||= Workflow.find(params[:workflow_id])
  end

  def user_info
    {
      id: current_user.id,
      email: current_user.email,
      name: current_user.email.split("@").first.titleize
    }
  end

  def broadcast_presence_update(workflow, **message)
    ActionCable.server.broadcast("workflow:#{workflow.id}:presence", {
                                   **message,
                                   active_users: WorkflowPresence.active_users(workflow.id),
                                   timestamp: Time.current.iso8601
                                 })
  end
end
