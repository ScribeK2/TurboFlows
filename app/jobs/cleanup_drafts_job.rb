class CleanupDraftsJob < ApplicationJob
  queue_as :default

  def perform
    count = Workflow.cleanup_expired_drafts
    Rails.logger.info("[CleanupDraftsJob] Cleaned up #{count} expired draft(s)")
  end
end
