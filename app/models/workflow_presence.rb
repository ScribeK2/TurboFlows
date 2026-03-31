class WorkflowPresence < ApplicationRecord
  belongs_to :workflow
  belongs_to :user

  scope :active, -> { where("last_seen_at > ?", 30.seconds.ago) }
  scope :for_workflow, ->(workflow_id) { where(workflow_id: workflow_id) }

  def self.track(workflow_id:, user_id:, user_name:, user_email:)
    upsert(
      { workflow_id: workflow_id, user_id: user_id, user_name: user_name, user_email: user_email, last_seen_at: Time.current },
      unique_by: [:workflow_id, :user_id]
    )
  end

  def self.untrack(workflow_id:, user_id:)
    where(workflow_id: workflow_id, user_id: user_id).delete_all
  end

  def self.active_users(workflow_id)
    for_workflow(workflow_id).active.pluck(:user_id, :user_email, :user_name).map do |id, email, name|
      { id: id, email: email, name: name }
    end
  end
end
