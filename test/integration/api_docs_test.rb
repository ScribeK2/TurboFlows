require "test_helper"

class ApiDocsTest < ActionDispatch::IntegrationTest
  test "a signed-in person gets the reference page, loading the vendored viewer and the spec" do
    sign_in User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                         password_confirmation: "password123!", role: "user")
    get api_docs_path
    assert_response :success
    assert_equal "text/html", response.media_type
    assert_includes response.body, api_v1_openapi_path
    assert_match(/<script[^>]+src="[^"]*scalar-api-reference[^"]*"/, response.body)
    assert_no_match(/cdn\.jsdelivr|unpkg\.com|fonts\.scalar/, response.body)
  end

  test "signed out, it asks you to sign in" do
    get api_docs_path
    assert_redirected_to new_user_session_path
  end

  test "the /api catch-all doesn't swallow the docs page" do
    assert_equal "api_docs", Rails.application.routes.recognize_path("/api/docs")[:controller]
  end
end
