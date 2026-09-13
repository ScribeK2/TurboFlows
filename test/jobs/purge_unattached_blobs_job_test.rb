require "test_helper"

# Lexxy uploads an image the moment it is chosen, so an image removed before its
# step saves, or chosen in an editor that is closed without saving, leaves a blob
# nothing attaches, and nothing else ever removes it. The sweep purges those once
# they are older than the grace period, so an edit still in progress keeps its
# upload.
class PurgeUnattachedBlobsJobTest < ActiveJob::TestCase
  setup do
    @editor = User.create!(email: "blob-sweep-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
  end

  test "can be enqueued" do
    assert_enqueued_with(job: PurgeUnattachedBlobsJob) { PurgeUnattachedBlobsJob.perform_later }
  end

  test "purges an unattached upload older than the grace period, file included" do
    blob = upload(age: PurgeUnattachedBlobsJob::GRACE + 1.hour)

    PurgeUnattachedBlobsJob.perform_now

    assert_not ActiveStorage::Blob.exists?(blob.id)
    assert_not blob.service.exist?(blob.key)
  end

  test "keeps an unattached upload younger than the grace period, since its edit may still be going" do
    blob = upload(age: PurgeUnattachedBlobsJob::GRACE - 1.hour)

    PurgeUnattachedBlobsJob.perform_now

    assert ActiveStorage::Blob.exists?(blob.id)
    assert blob.service.exist?(blob.key)
  ensure
    blob&.purge
  end

  test "keeps an old upload that a step's rich text still embeds" do
    blob = upload(age: 30.days)
    workflow = Workflow.create!(title: "Sweep #{SecureRandom.hex(3)}", user: @editor)
    Steps::Action.create!(workflow:, title: "Look", position: 0,
                          instructions: ActionText::Attachment.from_attachable(blob).to_html)

    PurgeUnattachedBlobsJob.perform_now

    assert ActiveStorage::Blob.exists?(blob.id), "swept an image a step still shows"
    assert blob.service.exist?(blob.key)
  end

  # Showing an image resized records the copy in active_storage_variant_records.
  # Destroying the original clears those records, and each copy's own image is
  # purged in a queued job, so the queue runs here too.
  test "purges an old unattached upload that was shown resized, along with the resized copy" do
    blob = upload(age: 30.days)
    resized = blob.representation(resize_to_limit: [100, 100]).processed.image.blob

    perform_enqueued_jobs { PurgeUnattachedBlobsJob.perform_now }

    assert_not ActiveStorage::VariantRecord.exists?(blob_id: blob.id)
    assert_not ActiveStorage::Blob.exists?(resized.id)
    assert_not ActiveStorage::Blob.exists?(blob.id)
    assert_not blob.service.exist?(blob.key)
  end

  private

  def upload(age:)
    blob = ActiveStorage::Blob.create_and_upload!(io: file_fixture("sample_image.png").open,
                                                  filename: "sweep-test.png", content_type: "image/png")
    ActiveStorage::Blob.where(id: blob.id).update_all(created_at: age.ago)
    blob
  end
end
