require "test_helper"

class Workflows::VersionsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @editor = User.create!(
      email: "versions-editor-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Versioned Flow", user: @editor, is_public: true)
    sign_in @editor
  end

  test "index lists versions" do
    get workflow_versions_path(@workflow)
    assert_response :success
  end

  test "index shows published versions" do
    WorkflowVersion.create!(
      workflow: @workflow,
      version_number: 1,
      steps_snapshot: [],
      published_at: Time.current,
      published_by: @editor
    )
    get workflow_versions_path(@workflow)
    assert_response :success
  end

  test "index requires authentication" do
    sign_out @editor
    get workflow_versions_path(@workflow)
    assert_redirected_to new_user_session_path
  end

  test "index redirects regular users to player" do
    regular_user = User.create!(
      email: "versions-regular-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
    sign_in regular_user
    get workflow_versions_path(@workflow)
    assert_redirected_to play_path
  end
end
