# config/application.rb
require_relative "boot"

require "rails/all"

# === CRITICAL: Load Devise BEFORE any models ===
require "devise"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module TurboFlows
  class Application < Rails::Application
    config.load_defaults 8.1

    # Timezone configuration
    # Store all times in UTC in the database (critical for SQLite/PostgreSQL consistency)
    config.active_record.default_timezone = :utc
    # Display times in UTC (can be overridden per-user if needed)
    config.time_zone = "UTC"

    # JavaScript via importmap-rails (no Node.js required)
    # CSS via Propshaft + vanilla CSS (no Tailwind)

    # Solid Queue uses a separate database for job storage
    config.solid_queue.connects_to = { database: { writing: :queue } }

    # Trust proxy IPs so Rails reads the real client IP from X-Forwarded-For.
    # Required for Rack::Attack rate limiting behind a load balancer or reverse proxy.
    # Set TRUSTED_PROXY_IPS to a comma-separated list of CIDRs, e.g. "10.0.0.0/8,172.16.0.0/12"
    if ENV["TRUSTED_PROXY_IPS"].present?
      custom_proxies = ENV["TRUSTED_PROXY_IPS"].split(",").map { |ip| IPAddr.new(ip.strip) }
      config.action_dispatch.trusted_proxies = ActionDispatch::RemoteIp::TRUSTED_PROXIES + custom_proxies
    end
  end
end
