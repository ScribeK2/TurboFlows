require "test_helper"

class RackAttackTest < ActionDispatch::IntegrationTest
  setup do
    # Clear rack-attack cache between tests
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.reset!
  end

  test "throttles excessive login attempts" do
    11.times do
      post user_session_path, params: { user: { email: "test@example.com", password: "wrongpassword!" } }
    end

    assert_equal 429, response.status
  end

  test "allows normal login attempts within limit" do
    5.times do
      post user_session_path, params: { user: { email: "test@example.com", password: "wrongpassword!" } }
    end

    assert_not_equal 429, response.status
  end

  test "uses X-Forwarded-For when trusted proxy is configured" do
    unless ENV["TRUSTED_PROXY_IPS"]
      skip "Requires TRUSTED_PROXY_IPS at boot (e.g. TRUSTED_PROXY_IPS=203.0.113.0/24 bin/rails test)"
    end

    # Use a public (non-RFC-1918) proxy IP so Rack doesn't already trust it.
    # 203.0.113.x is TEST-NET-3 (RFC 5737) — reserved for documentation, never
    # in Rack's built-in trusted proxy list.
    proxy_ip = "203.0.113.1"

    # First user hits login limit
    11.times do
      post user_session_path,
        params: { user: { email: "user1@example.com", password: "wrongpassword!" } },
        headers: { "REMOTE_ADDR" => proxy_ip, "HTTP_X_FORWARDED_FOR" => "192.168.1.10" }
    end

    assert_equal 429, response.status, "First user should be throttled after 11 attempts"

    # Second user from same proxy but different forwarded IP should NOT be throttled
    post user_session_path,
      params: { user: { email: "user2@example.com", password: "wrongpassword!" } },
      headers: { "REMOTE_ADDR" => proxy_ip, "HTTP_X_FORWARDED_FOR" => "192.168.1.20" }

    assert_not_equal 429, response.status, "Second user should not be throttled by first user's attempts"
  end
end
