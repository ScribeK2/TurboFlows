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

  test "/mcp is limited per token at 60 a minute, with a JSON 429" do
    freeze_time do
      60.times do
        post mcp_path, params: list_tools, headers: mcp_headers(@one)
        assert_operator response.status, :<, 429
      end
      post mcp_path, params: list_tools, headers: mcp_headers(@one)
      assert_response :too_many_requests
      assert_equal "throttled", response.parsed_body.dig("errors", 0, "code")

      post mcp_path, params: list_tools, headers: mcp_headers(@two)
      assert_operator response.status, :<, 429
    end
  end

  # Rack::Attack's own middleware already normalizes env['PATH_INFO'] with
  # ActionDispatch::Journey::Router::Utils before any throttle block runs (see
  # the comment on Rack::Attack.normalized_path), so by the time these three
  # shapes reach our code they already share one path. That makes this an
  # end-to-end proof the bucket is shared, not a test of the normalization
  # itself — test/integration/rack_attack_test.rb drives Rack::Attack.mcp?
  # and .drafts? directly against an unnormalized path, which is the only
  # place a regression in our own normalized_path helper could show up.
  test "/mcp/ and /mcp// count toward the same per-token bucket as /mcp" do
    freeze_time do
      20.times { post "/mcp", params: list_tools, headers: mcp_headers(@one) }
      20.times { post "/mcp/", params: list_tools, headers: mcp_headers(@one) }
      20.times { post "/mcp//", params: list_tools, headers: mcp_headers(@one) }
      assert_operator response.status, :<, 429

      post "/mcp", params: list_tools, headers: mcp_headers(@one)
      assert_response :too_many_requests
      assert_equal "throttled", response.parsed_body.dig("errors", 0, "code")
    end
  end

  # Same caveat as the /mcp variant test above: Rack::Attack normalizes the
  # path before our drafts? check ever runs, so this proves the bucket is
  # shared end-to-end rather than exercising Rack::Attack.drafts? directly.
  test "/api//v1/drafts/validate counts toward the drafts bucket" do
    freeze_time do
      20.times do
        post "/api//v1/drafts/validate", params: "{}", headers: headers(@one)
        assert_response :success
      end

      post "/api//v1/drafts/validate", params: "{}", headers: headers(@one)
      assert_response :too_many_requests
      assert_equal "throttled", response.parsed_body.dig("errors", 0, "code")
    end
  end

  private

  def headers(token)
    { "Authorization" => "Bearer #{token.plaintext}", "Content-Type" => "application/json" }
  end

  def list_tools = { jsonrpc: "2.0", id: "1", method: "tools/list", params: {} }.to_json

  def mcp_headers(token)
    { "Authorization" => "Bearer #{token.plaintext}", "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream", "MCP-Protocol-Version" => "2025-06-18" }
  end
end
