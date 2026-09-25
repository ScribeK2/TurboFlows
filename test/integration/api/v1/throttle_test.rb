require "test_helper"

class Api::V1::ThrottleTest < ActionDispatch::IntegrationTest
  setup do
    @editor = User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @one = ApiToken.issue(user: @editor, name: "one", scopes: %w[read draft], expires_in_days: 7)
    @two = ApiToken.issue(user: @editor, name: "two", scopes: %w[read draft], expires_in_days: 7)
  end

  test "the draft limit is per token, and a 429 is JSON with Retry-After" do
    # Rack::Attack windows are clock-aligned (Time.now.to_i / period), so 21
    # requests made across a real clock can straddle a minute boundary and land
    # in two different buckets. freeze_time keys every request to the same
    # instant, so the window can never roll over mid-test.
    freeze_time do
      20.times do
        post api_v1_draft_validation_path, params: "{}", headers: headers(@one)
        assert_response :success
      end

      post api_v1_draft_validation_path, params: "{}", headers: headers(@one)
      assert_response :too_many_requests
      assert_equal "throttled", response.parsed_body.dig("errors", 0, "code")
      assert_predicate response.headers["Retry-After"].to_i, :positive?

      post api_v1_draft_validation_path, params: "{}", headers: headers(@two)
      assert_response :success
    end
  end

  test "the read limit is per token" do
    freeze_time do
      120.times do
        get api_v1_workflows_path, headers: headers(@one)
        assert_response :success
      end
      get api_v1_workflows_path, headers: headers(@one)
      assert_response :too_many_requests
      get api_v1_workflows_path, headers: headers(@two)
      assert_response :success
    end
  end

  test "a throttled page outside the API is still the HTML page" do
    freeze_time do
      11.times { post user_session_path, params: { user: { email: "x@example.com", password: "nope" } } }
      assert_response :too_many_requests
      assert_match "text/html", response.content_type
    end
  end

  private

  def headers(token)
    { "Authorization" => "Bearer #{token.plaintext}", "Content-Type" => "application/json" }
  end
end
