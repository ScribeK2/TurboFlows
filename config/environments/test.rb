require 'active_support/core_ext/integer/time'

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Do not eager load code on boot. This avoids loading your whole application
  # just for the purpose of running a single test.
  config.eager_load = false

  # Configure public file server for tests with Cache-Control for performance.
  config.public_file_server.enabled = true
  config.public_file_server.headers = {
    'Cache-Control' => 'public, max-age=3600'
  }

  # Show full error reports and disable caching.
  config.consider_all_requests_local = true
  config.action_controller.perform_caching = false
  config.cache_store = :null_store

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  # Store uploaded files on the local file system in a temporary directory.
  config.active_storage.service = :test
  config.active_storage.variant_processor = :mini_magick

  # Disable Action Mailer's delivery in test environment.
  config.action_mailer.delivery_method = :test

  # Report deprecation notices in test output.
  config.active_support.report_deprecations = true

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true

  # Default URL options for Devise
  config.action_mailer.default_url_options = { host: 'localhost', port: 3000 }

  # Configure Action Mailer for testing
  config.action_mailer.perform_deliveries = true
  config.action_mailer.raise_delivery_errors = false
  config.action_mailer.delivery_method = :test

  # Set default from address for Devise emails
  config.action_mailer.default_options = {
    from: 'test@example.com'
  }

  # Configure Action Cable for test environment
  config.action_cable.disable_request_forgery_protection = true

  # ==========================================================================
  # Bullet Configuration - N+1 Query Detection in Tests
  # ==========================================================================
  # Enable detection but log only — do not raise exceptions.
  # There are 85+ existing N+1 patterns that need fixing in a separate PR.
  # Set Bullet.raise = true after those are resolved.
  config.after_initialize do
    Bullet.enable = true
    Bullet.bullet_logger = true
    Bullet.raise = false
  end
end
