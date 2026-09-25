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

  test "the init config hides the client-to-client.scalar.com link and disables Scalar's hosted features" do
    sign_in User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                         password_confirmation: "password123!", role: "user")
    get api_docs_path
    assert_response :success

    assert_match(/hideClientButton:\s*true/, response.body)
    assert_match(/agent:\s*\{\s*disabled:\s*true\s*\}/, response.body)
    assert_match(/mcp:\s*\{\s*disabled:\s*true\s*\}/, response.body)
    assert_match(/showDeveloperTools:\s*"never"/, response.body)
    # The button that hides "Test Request" is left unset (its default is
    # false): assert it's never assigned a value, not that the key's name
    # never appears at all — the view's own comment names it in explaining
    # why it's absent, which a bare string search would trip over.
    assert_no_match(/hideTestRequestButton\s*:/, response.body)
  end

  test "signed out, it asks you to sign in" do
    get api_docs_path
    assert_redirected_to new_user_session_path
  end

  test "the /api catch-all doesn't swallow the docs page" do
    assert_equal "api_docs", Rails.application.routes.recognize_path("/api/docs")[:controller]
  end

  # Item 5 of the Phase 3 review: without format: false, /api/docs.json
  # matched api_docs#show — Devise's HTML redirect signed out, or a missing
  # template signed in — a third, undocumented error shape. format: false
  # makes the route match only the exact path, so a .json suffix falls
  # through to the /api namespace's own JSON 404 catch-all.
  test "GET /api/docs.json falls to the API's JSON 404, never api_docs#show" do
    sign_in User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                         password_confirmation: "password123!", role: "user")
    get "/api/docs.json"
    assert_response :not_found
    assert_equal "application/json", response.media_type
    assert_equal "not_found", response.parsed_body.dig("errors", 0, "code")
  end
end
