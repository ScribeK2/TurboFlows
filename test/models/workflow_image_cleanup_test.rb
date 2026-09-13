require "test_helper"

# Deleting a workflow must take the images its steps' rich text embeds with it.
# Workflow#nullify_start_step used to delete_all those rich texts, which skips
# their callbacks, so each image's attachment row, blob and file outlived the
# workflow (found 2026-09-13, the day Lexxy uploads first worked). A purge must
# still never take an image something else shows: another workflow's step, or
# the steps a version restore rebuilds from the same snapshot.
class WorkflowImageCleanupTest < ActiveSupport::TestCase
  # Purges are queued (Active Storage's purge_later), so each test runs the
  # queued jobs to see what is really left behind.
  include ActiveJob::TestHelper

  setup do
    @editor = User.create!(email: "image-cleanup-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
  end

  test "deleting a workflow purges the images its steps embed" do
    blob = image_blob
    workflow = workflow_showing(blob)

    perform_enqueued_jobs { workflow.destroy! }

    assert_not ActiveStorage::Attachment.exists?(blob_id: blob.id), "the embed attachment outlived its rich text"
    assert_not ActiveStorage::Blob.exists?(blob.id), "the blob outlived the workflow"
    assert_not blob.service.exist?(blob.key), "the file is still in storage"
  end

  test "an image another workflow still embeds survives deleting one of them, and goes with the last" do
    blob = image_blob
    first = workflow_showing(blob)
    second = workflow_showing(blob)

    perform_enqueued_jobs { first.destroy! }

    assert ActiveStorage::Blob.exists?(blob.id), "purged an image another workflow still shows"
    assert blob.service.exist?(blob.key)
    assert_includes second.reload.steps.first.instructions.body.attachables, blob

    perform_enqueued_jobs { second.destroy! }

    assert_not ActiveStorage::Blob.exists?(blob.id), "the blob outlived the last workflow showing it"
    assert_not blob.service.exist?(blob.key)
  end

  test "restoring a version keeps the images its snapshot embeds" do
    blob = image_blob
    workflow = file_in_global(workflow_showing(blob))
    WorkflowPublisher.publish(workflow, @editor)
    version = workflow.versions.order(:created_at).last

    perform_enqueued_jobs do
      StepBuilder.call(workflow, version.steps_snapshot,
                       start_node_uuid: version.metadata_snapshot["start_node_uuid"], replace: true)
    end

    assert ActiveStorage::Blob.exists?(blob.id), "restoring purged an image the restored step shows"
    assert blob.service.exist?(blob.key)
    restored = workflow.reload.steps.find_by(type: "Steps::Action")
    assert_includes restored.instructions.body.attachables, blob
  end

  private

  def image_blob
    ActiveStorage::Blob.create_and_upload!(io: file_fixture("sample_image.png").open,
                                           filename: "sample_image.png", content_type: "image/png")
  end

  # An Action step whose instructions embed `blob`, leading to a Resolve.
  def workflow_showing(blob)
    workflow = Workflow.create!(title: "Images #{SecureRandom.hex(3)}", user: @editor)
    action = Steps::Action.create!(workflow:, title: "Look at this", position: 0,
                                   instructions: "<p>Router lights:</p>#{ActionText::Attachment.from_attachable(blob).to_html}")
    resolve = Steps::Resolve.create!(workflow:, title: "Done", position: 1, resolution_type: "success")
    Transition.create!(step_id: action.id, target_step_id: resolve.id, position: 0)
    workflow.update!(start_step: action)
    assert_includes action.reload.instructions.embeds.blobs, blob, "setup: the step should embed the image"
    workflow
  end
end
