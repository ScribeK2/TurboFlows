# Rate limiting configuration
# See: https://github.com/rack/rack-attack

class Rack::Attack
  # Use the real client IP resolved by ActionDispatch::RemoteIp (honours
  # TRUSTED_PROXY_IPS / X-Forwarded-For).  Falls back to Rack's req.ip so
  # tests and environments without the middleware still work.
  def self.client_ip(req)
    req.env.fetch("action_dispatch.remote_ip", req.ip).to_s
  end

  # Throttle login attempts by IP
  throttle("logins/ip", limit: 10, period: 60.seconds) do |req|
    client_ip(req) if req.path == "/users/sign_in" && req.post?
  end

  # Throttle password reset requests by IP
  throttle("password_resets/ip", limit: 5, period: 300.seconds) do |req|
    client_ip(req) if req.path == "/users/password" && req.post?
  end

  # Throttle admin password resets by IP
  throttle("admin_password_resets/ip", limit: 5, period: 300.seconds) do |req|
    client_ip(req) if req.path.match?(%r{\A/admin/users/\d+/reset_password\z}) && req.post?
  end

  # Throttle player scenario access by IP to prevent ID enumeration
  throttle("player_scenarios/ip", limit: 30, period: 60.seconds) do |req|
    client_ip(req) if req.path.match?(%r{\A/player/scenarios/\d+}) && req.get?
  end
end
