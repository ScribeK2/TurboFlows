# Rate limiting configuration
# See: https://github.com/rack/rack-attack
#
# Nothing here counts per client IP when there is anything better to count by.
# In production every request reaches Rails from one address: host nginx
# forwards raw TCP to kamal-proxy, which cannot add X-Forwarded-For, so the app
# sees 172.18.0.1 for everyone. A per-IP limit there is a single bucket for the
# whole company — it was ten sign-ins a minute and thirty run pages a minute,
# for everyone. So limits count per submitted email, per signed-in user or per
# session, and a company-wide backstop remains only where guessing is the
# threat. Run pages have no backstop: it would be the same failure with a
# bigger bucket.
#
# API requests count per token (the SHA-256 of the bearer value, never the raw
# token). The key is computed before authentication, so a flood of made-up
# tokens gets a fresh bucket each and only api/all catches it: per-token limits
# keep one real client well-behaved, they are not the abuse defense.

class Rack::Attack
  # The page a throttled person sees. Read once; it is a static file.
  THROTTLED_PAGE = Rails.public_path.join("429.html").read.freeze

  DRAFTS_PATH = "/api/v1/drafts".freeze

  # Use the real client IP resolved by ActionDispatch::RemoteIp (honours
  # TRUSTED_PROXY_IPS / X-Forwarded-For).  Falls back to Rack's req.ip so
  # tests and environments without the middleware still work. Only the last
  # resort: see above.
  def self.client_ip(req)
    req.env.fetch("action_dispatch.remote_ip", req.ip).to_s
  end

  def self.submitted_email(req)
    req.params.dig("user", "email").to_s.strip.downcase.presence
  end

  # The signed-in user's id, read from the session Warden wrote. No query, and
  # none of Devise's hooks — asking Warden for the user would run timeoutable,
  # which refreshes (or ends) the session before the controller has decided.
  def self.session_user_id(req)
    req.env["rack.session"]&.[]("warden.user.user.key")&.dig(0, 0)
  end

  def self.session_id(req)
    req.env["rack.session"]&.id&.to_s
  end

  def self.sign_in?(req)
    req.path == "/users/sign_in" && req.post?
  end

  def self.password_reset?(req)
    req.path == "/users/password" && req.post?
  end

  def self.run_page?(req)
    req.path.match?(%r{\A/player/scenarios/\d+}) && req.get?
  end

  # Rack::Attack's own #call already rewrites env['PATH_INFO'] with this same
  # function (PathNormalizer, gems/rack-attack/lib/rack/attack.rb) before any
  # throttle block or the responder ever sees a request, so req.path below is
  # already normalized. This helper is a second line, not the only one: it
  # keeps every API-shaped check correct even if rack-attack's own
  # normalization is ever removed, downgraded (its PathNormalizer falls back
  # to an identity function when ActionDispatch isn't loaded) or reordered,
  # and it keeps this file reading the same way Api::DraftBodyGuard does,
  # which normalizes for the same reason one middleware layer earlier, before
  # rack-attack has run at all.
  def self.normalized_path(req) = ActionDispatch::Journey::Router::Utils.normalize_path(req.path)

  def self.mcp?(req) = normalized_path(req) == "/mcp"

  def self.rest?(req) = normalized_path(req).start_with?("/api/")

  def self.drafts?(req)
    path = normalized_path(req)
    path == DRAFTS_PATH || path.start_with?("#{DRAFTS_PATH}/")
  end

  # REST and MCP: which throttles count, and which 429 body a caller gets.
  def self.api?(req) = rest?(req) || mcp?(req)

  def self.api_token_key(req)
    raw = ApiToken.raw_from_authorization(req.get_header("HTTP_AUTHORIZATION"))
    "token:#{ApiToken.digest(raw)}" if raw
  end

  # Throttle login attempts per email, with a company-wide backstop
  throttle("logins/email", limit: 10, period: 60.seconds) do |req|
    submitted_email(req) if sign_in?(req)
  end

  throttle("logins/all", limit: 300, period: 60.seconds) do |req|
    "all" if sign_in?(req)
  end

  # Throttle password reset requests per email, with a company-wide backstop
  throttle("password_resets/email", limit: 5, period: 300.seconds) do |req|
    submitted_email(req) if password_reset?(req)
  end

  throttle("password_resets/all", limit: 50, period: 300.seconds) do |req|
    "all" if password_reset?(req)
  end

  # Throttle admin password resets per administrator
  throttle("admin_password_resets/admin", limit: 5, period: 300.seconds) do |req|
    if req.path.match?(%r{\A/admin/users/\d+/reset_password\z}) && req.post?
      user_id = session_user_id(req)
      user_id ? "user:#{user_id}" : "ip:#{client_ip(req)}"
    end
  end

  # Throttle player scenario access to prevent ID enumeration: per signed-in
  # user, and per session for share-link visitors. A request with no session at
  # all falls back to the address.
  throttle("player_scenarios/user", limit: 60, period: 60.seconds) do |req|
    if run_page?(req)
      user_id = session_user_id(req)
      "user:#{user_id}" if user_id
    end
  end

  throttle("player_scenarios/visitor", limit: 30, period: 60.seconds) do |req|
    if run_page?(req) && session_user_id(req).nil?
      visitor = session_id(req)
      visitor ? "session:#{visitor}" : "ip:#{client_ip(req)}"
    end
  end

  throttle("api/token/read", limit: 120, period: 60.seconds) do |req|
    api_token_key(req) if rest?(req) && req.get?
  end

  throttle("api/token/draft", limit: 20, period: 60.seconds) do |req|
    api_token_key(req) if req.post? && drafts?(req)
  end

  # Every MCP call, whatever the tool: the throttle can't see which tool
  # without parsing the body, which Rack::Attack shouldn't do. 60 fits an
  # agent's guide -> search -> validate -> fix -> validate -> create loop with
  # room to spare (spec section 4; the live check in the Phase 2 plan records
  # a real session's count).
  throttle("api/token/mcp", limit: 60, period: 60.seconds) do |req|
    api_token_key(req) if mcp?(req)
  end

  throttle("api/all", limit: 1200, period: 60.seconds) do |req|
    "all" if api?(req)
  end

  # A readable page, and when to try again. The default is a bare "Retry later"
  # in plain text, which is what someone on a live call would have been shown.
  self.throttled_responder = lambda do |req|
    match = req.env["rack.attack.match_data"] || {}
    period = match[:period].to_i
    retry_after = period.positive? ? period - (match[:epoch_time].to_i % period) : 60

    headers = { "retry-after" => retry_after.to_s }
    if api?(req)
      body = { errors: [{ path: nil, code: "throttled",
                          message: "Too many requests. Try again in #{retry_after} seconds." }] }.to_json
      [429, headers.merge("content-type" => "application/json"), [body]]
    else
      [429, headers.merge("content-type" => "text/html; charset=utf-8"), [THROTTLED_PAGE]]
    end
  end
end
