require "test_helper"

class Workflows::PreviewsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @editor = User.create!(
      email: "preview-editor-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Preview Flow", user: @editor, is_public: true)
    sign_in @editor
  end

  test "show renders preview with step params" do
    get workflow_preview_path(@workflow), params: {
      step: { type: "question", title: "Test Q", question: "Are you sure?", answer_type: "yes_no" },
      step_index: 0
    }
    assert_response :success
  end

  test "show handles missing step params gracefully" do
    get workflow_preview_path(@workflow)
    assert_response :success
  end

  test "show requires authentication" do
    sign_out @editor
    get workflow_preview_path(@workflow)
    assert_redirected_to new_user_session_path
  end

  test "show redirects regular users to player" do
    regular_user = User.create!(
      email: "preview-regular-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
    sign_in regular_user
    get workflow_preview_path(@workflow)
    assert_redirected_to play_path
  end
end
