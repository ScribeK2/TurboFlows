require "test_helper"

class Workflows::SettingsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @editor = User.create!(
      email: "settings-editor-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Settings Flow", user: @editor, is_public: true)
    sign_in @editor
  end

  test "show renders settings panel partial" do
    get workflow_settings_path(@workflow)
    assert_response :success
  end

  test "show requires authentication" do
    sign_out @editor
    get workflow_settings_path(@workflow)
    assert_redirected_to new_user_session_path
  end

  test "show redirects regular users to player" do
    regular_user = User.create!(
      email: "settings-regular-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
    sign_in regular_user
    get workflow_settings_path(@workflow)
    assert_redirected_to play_path
  end
end
