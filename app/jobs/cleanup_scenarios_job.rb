class CleanupScenariosJob < ApplicationJob
  queue_as :default

  def perform
    count = Scenario.cleanup_stale
    Rails.logger.info("[CleanupScenariosJob] Cleaned up #{count} stale scenario(s)")
  end
end
