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

class Rack::Attack
  # The page a throttled person sees. Read once; it is a static file.
  THROTTLED_PAGE = Rails.public_path.join("429.html").read.freeze

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

  # A readable page, and when to try again. The default is a bare "Retry later"
  # in plain text, which is what someone on a live call would have been shown.
  self.throttled_responder = lambda do |req|
    match = req.env["rack.attack.match_data"] || {}
    period = match[:period].to_i
    retry_after = period.positive? ? period - (match[:epoch_time].to_i % period) : 60

    [429, { "content-type" => "text/html; charset=utf-8", "retry-after" => retry_after.to_s }, [THROTTLED_PAGE]]
  end
end
