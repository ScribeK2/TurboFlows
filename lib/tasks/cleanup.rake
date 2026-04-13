namespace :cleanup do
  desc "Delete stale scenarios past retention period"
  task scenarios: :environment do
    count = Scenario.cleanup_stale
    puts "Cleaned up #{count} stale scenario(s)."
  end

  desc "Delete expired draft workflows"
  task drafts: :environment do
    count = Workflow.cleanup_expired_drafts
    puts "Cleaned up #{count} expired draft(s)."
  end
end

namespace :workflows do
  desc "Delete orphaned draft workflows (untitled, no steps, older than 24 hours)"
  task cleanup_orphaned_drafts: :environment do
    count = Workflow.cleanup_orphaned_drafts
    puts "Cleaned up #{count} orphaned draft workflow(s)."
  end
end
