class CleanupDraftsJob < ApplicationJob
  queue_as :default

  def perform
    expired = Workflow.cleanup_expired_drafts
    orphaned = Workflow.cleanup_orphaned_drafts
    Rails.logger.info("[CleanupDraftsJob] Cleaned up #{expired} expired, #{orphaned} orphaned draft(s)")
  end
end
