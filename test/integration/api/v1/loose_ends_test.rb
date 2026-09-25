require "test_helper"

class Api::V1::LooseEndsTest < ActionDispatch::IntegrationTest
  setup do
    @editor = User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @reader = ApiToken.issue(user: @editor, name: "r", scopes: %w[read], expires_in_days: 7)
    @drafter = ApiToken.issue(user: @editor, name: "d", scopes: %w[draft], expires_in_days: 7)
  end

  test "an unknown /api path is a JSON 404 in the error shape, with or without a token" do
    [{}, auth(@reader)].each do |headers|
      get "/api/v1/nope", headers: headers
      assert_response :not_found
      assert_equal "application/json", response.media_type
      assert_equal "not_found", response.parsed_body.dig("errors", 0, "code")
    end
    post "/api/v2/anything", headers: auth(@reader)
    assert_response :not_found
  end

  test "array-valued filters are refused, not silently dropped" do
    get api_v1_workflows_path, params: { q: ["x"] }, headers: auth(@reader)
    assert_response :unprocessable_content
    assert_equal "invalid_filter", response.parsed_body.dig("errors", 0, "code")
    get api_v1_workflows_path, params: { status: { a: 1 } }, headers: auth(@reader)
    assert_response :unprocessable_content
  end

  test "a malformed JSON body on a GET is a 400 in the error shape, not an HTML page" do
    get api_v1_workflows_path, params: "{nope", headers: auth(@reader).merge("Content-Type" => "application/json")
    assert_includes [200, 400], response.status
    assert_equal "application/json", response.media_type
  end

  # ActionDispatch::Integration::Session#process folds a String `params:` on a
  # GET into the query string, never the body — so the test above can only
  # ever observe 200 (confirmed: it does). A real client is free to send a
  # GET with a body and Content-Type: application/json (Rack parses a request
  # body by content type, not by method), and WorkflowsController#index does
  # touch `params`, so BaseController's rescue is reachable in production.
  # Dispatch a raw Rack request, bypassing the harness's shortcut, to prove
  # the rescue itself actually fires rather than trusting the 200 above.
  test "a GET whose body the parser actually touches gets the rescue's 400, not an unhandled error" do
    mock = Rack::MockRequest.new(Rails.application)
    resp = mock.get("/api/v1/workflows", input: "{nope",
                                         "CONTENT_TYPE" => "application/json",
                                         "HTTP_AUTHORIZATION" => "Bearer #{@reader.plaintext}")
    assert_equal 400, resp.status
    assert_equal "application/json", Rack::MediaType.type(resp.content_type)
    assert_equal "malformed_json", JSON.parse(resp.body).dig("errors", 0, "code")
  end

  test "a GET on the POST-only drafts routes is still the API's plain 404" do
    get api_v1_drafts_path, headers: auth(@reader)
    assert_response :not_found
    assert_equal "not_found", response.parsed_body.dig("errors", 0, "code")

    get api_v1_draft_validation_path, headers: auth(@reader)
    assert_response :not_found
    assert_equal "not_found", response.parsed_body.dig("errors", 0, "code")
  end

  test "a draft-only token reads the authoring guide, as MCP already allows" do
    get api_v1_authoring_guide_path, headers: auth(@drafter)
    assert_response :success
  end

  private

  def auth(token) = { "Authorization" => "Bearer #{token.plaintext}" }
end
