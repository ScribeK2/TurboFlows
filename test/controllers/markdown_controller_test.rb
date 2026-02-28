require "test_helper"

class MarkdownControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  self.use_transactional_tests = true

  def setup
    @user = User.create!(
      email: "mdtest@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
  end

  test "preview renders markdown to HTML for authenticated user" do
    sign_in @user
    post markdown_preview_path, params: { text: "**bold** and _italic_" },
         headers: { "Accept" => "text/html" }

    assert_response :success
    assert_includes response.body, "<strong>bold</strong>"
    assert_includes response.body, "<em>italic</em>"
    assert_includes response.body, 'class="step-markdown-content"'
  end

  test "preview returns empty div for blank text" do
    sign_in @user
    post markdown_preview_path, params: { text: "" },
         headers: { "Accept" => "text/html" }

    assert_response :success
  end

  test "preview requires authentication" do
    post markdown_preview_path, params: { text: "hello" }

    assert_redirected_to new_user_session_path
  end

  test "preview sanitizes dangerous HTML" do
    sign_in @user
    post markdown_preview_path,
         params: { text: '<script>alert("xss")</script>' },
         headers: { "Accept" => "text/html" }

    assert_response :success
    refute_includes response.body, "<script>"
  end
end
