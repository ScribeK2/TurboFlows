# config/application.rb
require_relative "boot"

require "rails/all"

# === CRITICAL: Load Devise BEFORE any models ===
require "devise"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Kizuflow
  class Application < Rails::Application
    config.load_defaults 8.1

    # Timezone configuration
    # Store all times in UTC in the database (critical for SQLite/PostgreSQL consistency)
    config.active_record.default_timezone = :utc
    # Display times in UTC (can be overridden per-user if needed)
    config.time_zone = "UTC"

    # JavaScript via importmap-rails (no Node.js required)
    # CSS via Propshaft + vanilla CSS (no Tailwind)
  end
end
