require "test_helper"

class StepMediaTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "media@test.com", password: "password123!", role: "admin")
    @workflow = Workflow.create!(title: "Media Flow", user: @user)
    @step = Steps::Action.create!(workflow: @workflow, title: "With Media", uuid: SecureRandom.uuid, position: 0)
  end

  test "step can have media attachments" do
    assert_respond_to @step, :media_attachments
  end

  test "media_image? returns true for image content types" do
    assert @step.media_image?("image/png")
    assert @step.media_image?("image/jpeg")
    assert_not @step.media_image?("application/pdf")
  end

  test "media_video? returns true for video content types" do
    assert @step.media_video?("video/mp4")
    assert_not @step.media_video?("image/png")
  end

  test "media_document? returns true for document content types" do
    assert @step.media_document?("application/pdf")
    assert_not @step.media_document?("image/png")
  end
end
