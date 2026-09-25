require "test_helper"

# In production every request reaches Rails from the same address (see
# config/initializers/rack_attack.rb), so every test here makes all of its
# requests from one IP. A limit that only holds apart from different addresses
# is a limit on the whole company.
class RackAttackTest < ActionDispatch::IntegrationTest
  PASSWORD = "password123!".freeze

  setup do
    # Clear rack-attack cache between tests
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.reset!
  end

  # A fixed instant `offset` seconds into the current rack-attack period, so a
  # run can never straddle the boundary between two counters.
  def bucket_start_plus(offset, period: 60)
    Time.zone.at(((Time.now.to_i / period) * period) + offset)
  end

  def create_user(role: "user")
    User.create!(email: "rack-#{SecureRandom.hex(4)}@test.com", password: PASSWORD,
                 password_confirmation: PASSWORD, role: role)
  end

  def attempt_sign_in(email, password: "wrongpassword!")
    post user_session_path, params: { user: { email: email, password: password } }
  end

  def request_password_reset(email)
    post user_password_path, params: { user: { email: email } }
  end

  def open_run_page
    get player_scenario_step_path(id: 1)
  end

  # === Sign-in ===

  test "throttles excessive login attempts" do
    # rack-attack buckets by wall clock, not by a sliding window: the cache key
    # embeds (Time.now.to_i / period), so eleven requests that happen to straddle
    # a minute boundary split into two counters of six and five. Neither exceeds
    # the limit of ten, nothing throttles, and the test fails with 200. That is
    # the whole story behind this test's intermittent failures — it read as
    # order-dependent only because test order changes where in the minute the
    # test lands. Pin the clock inside one bucket so it cannot straddle.
    travel_to bucket_start_plus(5) do
      11.times { attempt_sign_in("test@example.com") }
    end

    assert_equal 429, response.status
  end

  test "allows normal login attempts within limit" do
    5.times { attempt_sign_in("test@example.com") }

    assert_not_equal 429, response.status
  end

  test "sign-in attempts for different emails are counted apart" do
    travel_to bucket_start_plus(5) do
      10.times { attempt_sign_in("first@example.com") }
      10.times { attempt_sign_in("second@example.com") }
    end

    assert_not_equal 429, response.status
  end

  test "an email's sign-in attempts are counted together whatever its case or spacing" do
    travel_to bucket_start_plus(5) do
      10.times { attempt_sign_in("Casey@Example.com") }
      attempt_sign_in("  casey@example.com ")
    end

    assert_equal 429, response.status
  end

  test "a sign-in within the limit still signs in" do
    user = create_user

    travel_to bucket_start_plus(5) do
      3.times { attempt_sign_in(user.email) }
      attempt_sign_in(user.email, password: PASSWORD)
    end

    assert_redirected_to root_path
  end

  test "sign-ins stop company-wide past the backstop" do
    travel_to bucket_start_plus(5) do
      300.times { |i| attempt_sign_in("person#{i}@example.com") }

      assert_not_equal 429, response.status

      attempt_sign_in("one-more@example.com")
    end

    assert_equal 429, response.status
  end

  # === Password reset ===

  test "password resets are counted per email" do
    travel_to bucket_start_plus(5) do
      6.times { request_password_reset("forgetful@example.com") }

      assert_equal 429, response.status

      request_password_reset("someone-else@example.com")
    end

    assert_not_equal 429, response.status
  end

  test "password resets stop company-wide past the backstop" do
    travel_to bucket_start_plus(5, period: 300) do
      50.times { |i| request_password_reset("person#{i}@example.com") }

      assert_not_equal 429, response.status

      request_password_reset("one-more@example.com")
    end

    assert_equal 429, response.status
  end

  # === Run pages ===

  test "run pages are counted per signed-in user, not per address" do
    travel_to bucket_start_plus(5) do
      sign_in create_user
      40.times { open_run_page }
      sign_in create_user
      40.times { open_run_page }
    end

    assert_not_equal 429, response.status
  end

  test "a signed-in user is stopped after sixty run pages a minute" do
    travel_to bucket_start_plus(5) do
      sign_in create_user
      61.times { open_run_page }
    end

    assert_equal 429, response.status
  end

  # Each visitor first opens a page that writes a session (Devise stores where
  # to return after sign-in). The sign-in page would too in production, but only
  # through the CSRF token, and forgery protection is off in tests.
  test "run pages without a sign-in are counted per session" do
    travel_to bucket_start_plus(5) do
      get workflows_path
      31.times { open_run_page }

      assert_equal 429, response.status

      other_visitor = open_session
      other_visitor.get workflows_path
      other_visitor.get player_scenario_step_path(id: 1)

      assert_not_equal 429, other_visitor.response.status
    end
  end

  # === Admin password reset ===

  test "an administrator's password resets are counted per administrator" do
    target = create_user

    travel_to bucket_start_plus(5, period: 300) do
      sign_in create_user(role: "admin")
      6.times { post reset_password_admin_user_path(target) }

      assert_equal 429, response.status

      sign_in create_user(role: "admin")
      post reset_password_admin_user_path(target)
    end

    assert_not_equal 429, response.status
  end

  # === What a throttled person sees ===

  test "a throttled request gets a readable page and says when to try again" do
    travel_to bucket_start_plus(5) do
      11.times { attempt_sign_in("test@example.com") }
    end

    assert_equal 429, response.status
    assert_match "text/html", response.media_type
    assert_includes response.body, "Too many attempts"
    assert_includes 1..60, Integer(response.headers["Retry-After"])
  end

  # === Path normalization ===
  #
  # Rack::Attack's own #call rewrites env['PATH_INFO'] with
  # ActionDispatch::Journey::Router::Utils before any throttle block runs
  # (rack-attack's PathNormalizer), so a request driven through the full
  # stack — as every other test in this file and in throttle_test.rb is —
  # can never observe Rack::Attack.mcp?/.rest?/.drafts? disagreeing with that
  # normalization: both sides always see the same, already-normalized path.
  # These tests call the predicates directly against a raw, un-normalized env
  # (built the same way test/middleware/api/draft_body_guard_test.rb builds
  # one), which is the only place a regression in our own normalized_path
  # helper — or its removal — could ever show up.
  def unnormalized_request(path, method: "POST")
    Rack::Attack::Request.new(Rack::MockRequest.env_for(path, method: method))
  end

  test "mcp? recognizes /mcp, /mcp/ and /mcp// before any normalization by Rack::Attack itself" do
    assert Rack::Attack.mcp?(unnormalized_request("/mcp"))
    assert Rack::Attack.mcp?(unnormalized_request("/mcp/"))
    assert Rack::Attack.mcp?(unnormalized_request("/mcp//"))
    assert_not Rack::Attack.mcp?(unnormalized_request("/mcpx"))
  end

  test "drafts? recognizes /api//v1/drafts and /api//v1/drafts/validate before normalization by Rack::Attack itself" do
    assert Rack::Attack.drafts?(unnormalized_request("/api/v1/drafts"))
    assert Rack::Attack.drafts?(unnormalized_request("/api//v1/drafts"))
    assert Rack::Attack.drafts?(unnormalized_request("/api//v1/drafts/validate"))
    assert_not Rack::Attack.drafts?(unnormalized_request("/api/v1/drafts-other"))
  end

  test "rest? recognizes /api//v1/workflows before normalization by Rack::Attack itself" do
    assert Rack::Attack.rest?(unnormalized_request("/api//v1/workflows"))
    assert_not Rack::Attack.rest?(unnormalized_request("/mcp"))
  end
end
