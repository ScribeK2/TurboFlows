# Purges uploads nothing attaches. Lexxy uploads an image the moment it is
# chosen, so an image removed before its step saves, or chosen in an editor that
# is closed without saving, leaves a blob and a file that nothing else removes.
#
# GRACE keeps an upload whose edit may still be in progress. A blob attached in
# the meantime is safe anyway: Active Storage refuses to destroy a blob that has
# attachments, and Blob#purge then leaves it alone.
class PurgeUnattachedBlobsJob < ApplicationJob
  queue_as :default

  GRACE = 2.days

  def perform
    purged = 0
    ActiveStorage::Blob.unattached.where(created_at: ...GRACE.ago).find_each do |blob|
      blob.purge
      purged += 1 if blob.destroyed?
    end
    Rails.logger.info("[PurgeUnattachedBlobsJob] Purged #{purged} unattached upload(s)")
  end
end
