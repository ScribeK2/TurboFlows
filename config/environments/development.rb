require 'active_support/core_ext/integer/time'

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Do not eager load code on boot.
  config.eager_load = false

  # Show full error reports.
  config.consider_all_requests_local = true

  # Enable server timing.
  config.server_timing = true

  # Enable/disable caching. By default caching is disabled.
  # Run rails dev:cache to toggle caching.
  if Rails.root.join('tmp/caching-dev.txt').exist?
    config.action_controller.perform_caching = true
    config.action_controller.enable_fragment_cache_logging = true

    config.cache_store = :memory_store
    config.public_file_server.headers = {
      'Cache-Control' => "public, max-age=#{2.days.to_i}"
    }
  else
    config.action_controller.perform_caching = false

    config.cache_store = :null_store
  end

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local
  config.active_storage.variant_processor = :vips

  # Don't care if the mailer can't send.
  config.action_mailer.raise_delivery_errors = false

  config.action_mailer.perform_caching = false

  # Report deprecation notices to the Rails logger.
  config.active_support.report_deprecations = true

  # Raise an error on page load if there are pending migrations.
  config.active_record.migration_error = :page_load

  # Highlight code that triggered database queries in logs.
  config.active_record.verbose_query_logs = true

  # Highlight code that enqueued background job in logs.
  config.active_job.verbose_enqueue_logs = true

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Uncomment if you wish to allow Action Cable access from any origin.
  # config.action_cable.disable_request_forgery_protection = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true

  # Default URL options for Devise
  config.action_mailer.default_url_options = { host: 'localhost', port: 3000 }

  # Set default from address for Devise emails
  config.action_mailer.default_options = {
    from: 'development@example.com'
  }

  # ==========================================================================
  # Bullet Configuration - N+1 Query Detection
  # ==========================================================================
  # Bullet helps detect N+1 queries and unused eager loading
  # It will alert you during development when it finds issues
  config.after_initialize do
    Bullet.enable = true

    # Show JavaScript alert in browser (can be annoying, disable if needed)
    Bullet.alert = false

    # Log to bullet.log file
    Bullet.bullet_logger = true

    # Bullet.console and Bullet.add_footer inject inline <script> tags that are
    # blocked by the nonce-based CSP policy, generating false CSP violation errors.
    # Use bullet.log and rails log instead.
    Bullet.console = false

    # Add to Rails log
    Bullet.rails_logger = true

    # Disabled: injects inline scripts blocked by CSP nonce policy
    Bullet.add_footer = false

    # Raise errors in development (set to false if too aggressive)
    Bullet.raise = false

    # Skip detection for certain patterns (add if needed)
    # Bullet.add_safelist type: :unused_eager_loading, class_name: "Model", association: :association

    # Known N+1s that are intentional or can't be easily fixed
    # (Add entries here as needed during development)
    # Bullet.add_safelist type: :n_plus_one_query, class_name: "Workflow", association: :groups
  end
end
