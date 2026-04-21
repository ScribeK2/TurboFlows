require "active_support/core_ext/integer/time"
require_relative "../application"

Rails.application.configure do

  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Ensures that a master key has been made available in ENV["RAILS_MASTER_KEY"], config/master.key, or an environment
  # key such as config/credentials/production.key. This key is used to decrypt credentials (and other encrypted files).
  config.require_master_key = true

  # Enable static file serving from the `/public` folder (turn off if using NGINX/Apache for it).
  # On Render, we need to serve static files ourselves, so enable this
  # Static files served by Rails (importmap JS + Propshaft-compiled vanilla CSS)
  config.public_file_server.enabled = ENV.fetch("RAILS_SERVE_STATIC_FILES", "true") == "true"
  config.public_file_server.headers = {
    'Cache-Control' => "public, max-age=31536000"
  }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Specifies the header that your server uses for sending files.
  # config.action_dispatch.x_sendfile_header = "X-Sendfile" # for Apache
  # config.action_dispatch.x_sendfile_header = "X-Accel-Redirect" # for NGINX

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local
  config.active_storage.variant_processor = :mini_magick

  # Mount Action Cable outside main process or domain.
  # config.action_cable.mount_path = nil
  # config.action_cable.url = "wss://example.com/cable"
  # config.action_cable.allowed_request_origins = [ "http://example.com", /http:\/\/example.*/ ]

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  # Set DISABLE_SSL=true when TLS is terminated by a load balancer or during initial staging setup.
  config.force_ssl = ENV["DISABLE_SSL"] != "true"

  # Include generic and useful information about system operation, but avoid logging too much
  # information to avoid inadvertent exposure of personally identifiable information (PII).
  config.log_level = :info

  # Prepend all log lines with the following tags.
  config.log_tags = [ :request_id ]

  # Use Redis as cache store for cross-worker fragment caching
  config.cache_store = :redis_cache_store, {
    url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"),
    expires_in: 1.hour,
    error_handler: ->(method:, returning:, exception:) {
      Rails.logger.warn("Redis cache error: #{exception.message}")
    }
  }

  # Use a real queuing backend for Active Job (and separate queues per environment).
  config.active_job.queue_adapter = :solid_queue
  # config.active_job.queue_name_prefix = "turboflows_production"

  config.action_mailer.perform_caching = false

  # SMTP delivery — required for Devise password resets, account unlock, and email confirmation.
  # Set SMTP_ADDRESS to enable. Without it, mailer defaults to :sendmail (will fail silently
  # in most container environments).
  if ENV["SMTP_ADDRESS"].present?
    config.action_mailer.delivery_method = :smtp
    config.action_mailer.raise_delivery_errors = true
    config.action_mailer.smtp_settings = {
      address:         ENV.fetch("SMTP_ADDRESS"),
      port:            ENV.fetch("SMTP_PORT", 587).to_i,
      domain:          ENV.fetch("SMTP_DOMAIN", ENV.fetch("APP_HOST", "localhost")),
      user_name:       ENV["SMTP_USERNAME"],
      password:        ENV["SMTP_PASSWORD"],
      authentication:  ENV.fetch("SMTP_AUTHENTICATION", "plain"),
      enable_starttls: ENV.fetch("SMTP_STARTTLS", "true") == "true"
    }
  end

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Use default logging formatter so that PID and timestamp are not suppressed.
  config.log_formatter = ::Logger::Formatter.new

  # Use a different logger for distributed setups.
  # require "syslog/logger"
  # config.logger = ActiveSupport::TaggedLogging.new(Syslog::Logger.new "app-name")

  if ENV["RAILS_LOG_TO_STDOUT"].present?
    config.logger = ActiveSupport::TaggedLogging.logger($stdout)
  end

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Enable DNS rebinding protection and other `Host` header attacks.
  config.hosts = [
    ENV.fetch("APP_HOST", "localhost"),
    /.*\.#{Regexp.escape(ENV.fetch("APP_HOST", "localhost"))}/
  ]
  # Skip DNS rebinding protection for the default health check endpoint.
  config.hosts << "healthz"

  # Default URL options for Devise
  config.action_mailer.default_url_options = { host: ENV.fetch("HOST", "localhost") }
end
