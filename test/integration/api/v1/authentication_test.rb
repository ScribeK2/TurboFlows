require "test_helper"

class Api::V1::AuthenticationTest < ActionDispatch::IntegrationTest
  setup do
    @editor = User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @token = ApiToken.issue(user: @editor, name: "t", scopes: %w[read], expires_in_days: 7)
  end

  test "a valid token reads the authoring guide" do
    get api_v1_authoring_guide_path, headers: auth(@token.plaintext)
    assert_response :success
    body = response.parsed_body
    assert_equal ImportSchemaGenerator::SCHEMA_VERSION, body["schema_version"]
    assert_equal "object", body.dig("schema", "type")
    assert_predicate body["guide"], :present?
    assert @token.reload.last_used_at
  end

  test "lower-case bearer works" do
    get api_v1_authoring_guide_path, headers: { "Authorization" => "bearer #{@token.plaintext}" }
    assert_response :success
  end

  test "every bad credential is a 401 in the one error shape" do
    [nil, "Basic dXNlcjpwYXNz", "Bearer", "Bearer tf_live_unknown",
     "Bearer #{@token.plaintext.delete_prefix('tf_live_')}"].each do |header|
      get api_v1_authoring_guide_path, headers: header ? { "Authorization" => header } : {}
      assert_response :unauthorized, "header #{header.inspect}"
      assert_equal "unauthorized", response.parsed_body.dig("errors", 0, "code")
      assert_match(/Bearer/, response.headers["WWW-Authenticate"])
    end
  end

  test "revoked, expired and deactivated all answer 401" do
    raw = @token.plaintext
    travel_to(@token.expires_at + 1.second) do
      get api_v1_authoring_guide_path, headers: auth(raw)
      assert_response :unauthorized
    end

    @editor.update!(deactivated_at: Time.current)
    get api_v1_authoring_guide_path, headers: auth(raw)
    assert_response :unauthorized

    @editor.update!(deactivated_at: nil)
    @token.revoke!
    get api_v1_authoring_guide_path, headers: auth(raw)
    assert_response :unauthorized
  end

  test "a signed-in browser session alone does not authenticate the API" do
    sign_in @editor
    get api_v1_authoring_guide_path
    assert_response :unauthorized
  end

  private

  def auth(raw) = { "Authorization" => "Bearer #{raw}" }
end
