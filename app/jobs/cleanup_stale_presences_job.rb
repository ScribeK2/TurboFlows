class CleanupStalePresencesJob < ApplicationJob
  def perform
    WorkflowPresence.where("last_seen_at < ?", 5.minutes.ago).delete_all
  end
end
