require "active_support/core_ext/integer/time"
require_relative "../application"

Rails.application.configure do

  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Disable master key requirement — ONCE provides SECRET_KEY_BASE at runtime.
  # Also allows asset precompilation during Docker build without keys.
  config.require_master_key = false

  # Static files served by Rails (importmap JS + Propshaft-compiled vanilla CSS)
  config.public_file_server.enabled = ENV.fetch("RAILS_SERVE_STATIC_FILES", "true") == "true"
  config.public_file_server.headers = {
    'Cache-Control' => "public, max-age=31536000"
  }

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local
  config.active_storage.variant_processor = :mini_magick

  # SSL: controlled by ONCE's DISABLE_SSL env var
  config.assume_ssl = ENV["DISABLE_SSL"].blank?
  config.force_ssl = ENV["DISABLE_SSL"].blank?

  # Include generic and useful information about system operation, but avoid logging too much
  # information to avoid inadvertent exposure of personally identifiable information (PII).
  config.log_level = :info

  # Prepend all log lines with the following tags.
  config.log_tags = [ :request_id ]

  # Solid stack: SQLite-backed cache, queue, cable (no Redis)
  config.cache_store = :solid_cache_store
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  config.action_mailer.perform_caching = false

  # SMTP configuration from ONCE env vars
  if ENV["SMTP_ADDRESS"].present?
    config.action_mailer.delivery_method = :smtp
    config.action_mailer.smtp_settings = {
      address: ENV["SMTP_ADDRESS"],
      port: ENV.fetch("SMTP_PORT", 587).to_i,
      user_name: ENV["SMTP_USERNAME"],
      password: ENV["SMTP_PASSWORD"]
    }
  end
  config.action_mailer.default_options = {
    from: ENV.fetch("MAILER_FROM_ADDRESS", "noreply@example.com")
  }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Use default logging formatter so that PID and timestamp are not suppressed.
  config.log_formatter = ::Logger::Formatter.new

  # Log to stdout in containerized environments
  config.logger = ActiveSupport::TaggedLogging.logger($stdout)

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Host header protection: configurable via APP_HOST env var
  config.hosts << ENV["APP_HOST"] if ENV["APP_HOST"].present?

  # Default URL options for Devise and Action Mailer
  config.action_mailer.default_url_options = { host: ENV.fetch("APP_HOST", "localhost") }
end
