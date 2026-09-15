require "test_helper"

module Steps
  # A file chosen in the step panel is direct-uploaded and then attached here.
  # Until 2026-09-15 the panel form was not multipart and its file input had no
  # autosave action, so no file ever reached the server: the preview list showed
  # it attached and nothing was.
  class MediaAttachmentsControllerTest < ActionDispatch::IntegrationTest
    TURBO = { "Accept" => "text/vnd.turbo-stream.html" }.freeze

    setup do
      @editor = User.create!(email: "media-editor-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                             password_confirmation: "password123!", role: "editor")
      @workflow = Workflow.create!(title: "Media WF", user: @editor)
      @step = Steps::Action.create!(workflow: @workflow, position: 0, title: "With media")
      sign_in @editor
    end

    teardown do
      ActiveStorage::Blob.where(filename: %w[audit.png notes.txt]).find_each(&:purge)
    end

    test "attaches a direct-uploaded blob and streams the list back" do
      blob = upload_blob("audit.png", "image/png")

      assert_difference -> { @step.media_attachments.count }, 1 do
        post workflow_step_media_attachments_path(@workflow, @step), params: { signed_id: blob.signed_id }, headers: TURBO
      end

      assert_response :success
      assert_match(/<turbo-stream action="replace" target="#{ActionView::RecordIdentifier.dom_id(@step, :media)}"/, response.body)
      assert_match "audit.png", response.body
      assert_match "Remove", response.body
    end

    test "a second file is added after the first, not in its place" do
      @step.media_attachments.attach(upload_blob("audit.png", "image/png"))

      post workflow_step_media_attachments_path(@workflow, @step),
           params: { signed_id: upload_blob("audit.png", "image/png").signed_id }, headers: TURBO

      assert_equal 2, @step.reload.media_attachments.count
    end

    test "refuses a type the step does not allow and says so" do
      blob = upload_blob("notes.txt", "text/plain")

      assert_no_difference -> { @step.media_attachments.count } do
        post workflow_step_media_attachments_path(@workflow, @step), params: { signed_id: blob.signed_id }, headers: TURBO
      end

      assert_response :unprocessable_content
      assert_match(/<turbo-stream action="update" target="flash"/, response.body)
      assert_match "must be an image, video, or PDF", response.body
    end

    test "refuses a signed id that names no blob" do
      post workflow_step_media_attachments_path(@workflow, @step), params: { signed_id: "not-a-signed-id" }, headers: TURBO

      assert_response :unprocessable_content
      assert_match "could not be attached", response.body
    end

    test "removes an attachment and streams the list back" do
      @step.media_attachments.attach(upload_blob("audit.png", "image/png"))
      attachment = @step.media_attachments.attachments.first

      assert_difference -> { @step.media_attachments.count }, -1 do
        delete workflow_step_media_attachment_path(@workflow, @step, attachment), headers: TURBO
      end

      assert_response :success
      assert_match(/<turbo-stream action="replace" target="#{ActionView::RecordIdentifier.dom_id(@step, :media)}"/, response.body)
      assert_no_match "audit.png", response.body
    end

    test "removing an attachment that is already gone still answers with the list" do
      @step.media_attachments.attach(upload_blob("audit.png", "image/png"))
      attachment = @step.media_attachments.attachments.first
      attachment.purge

      delete workflow_step_media_attachment_path(@workflow, @step, attachment), headers: TURBO

      assert_response :success
      assert_match(/<turbo-stream action="replace" target="#{ActionView::RecordIdentifier.dom_id(@step, :media)}"/, response.body)
    end

    test "someone who may not edit the workflow is turned away" do
      other = User.create!(email: "media-other-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "regular")
      sign_in other
      blob = upload_blob("audit.png", "image/png")

      post workflow_step_media_attachments_path(@workflow, @step), params: { signed_id: blob.signed_id }, headers: TURBO

      assert_redirected_to workflows_path
      assert_equal 0, @step.reload.media_attachments.count
    end

    private

    def upload_blob(filename, content_type)
      ActiveStorage::Blob.create_and_upload!(io: StringIO.new("x" * 64), filename: filename, content_type: content_type)
    end
  end
end
