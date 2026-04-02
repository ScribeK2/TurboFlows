# Rate limiting configuration
# See: https://github.com/rack/rack-attack

class Rack::Attack
  # Throttle login attempts by IP
  throttle("logins/ip", limit: 10, period: 60.seconds) do |req|
    req.ip if req.path == "/users/sign_in" && req.post?
  end

  # Throttle password reset requests by IP
  throttle("password_resets/ip", limit: 5, period: 300.seconds) do |req|
    req.ip if req.path == "/users/password" && req.post?
  end

  # Throttle admin password resets by IP
  throttle("admin_password_resets/ip", limit: 5, period: 300.seconds) do |req|
    req.ip if req.path.match?(%r{\A/admin/users/\d+/reset_password\z}) && req.post?
  end

  # Throttle player scenario access by IP to prevent ID enumeration
  throttle("player_scenarios/ip", limit: 30, period: 60.seconds) do |req|
    req.ip if req.path.match?(%r{\A/player/scenarios/\d+}) && req.get?
  end
end
