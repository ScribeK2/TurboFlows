# Gemfile
source "https://rubygems.org"

ruby "4.0.6"

gem "bootsnap", ">= 1.4.4", require: false
gem "csv"
gem "importmap-rails"
gem "pg", "~> 1.1", group: [:production]
gem "propshaft"
gem "puma", "~> 8.0"
gem "rails", "~> 8.1.0"
gem "redis", "~> 6.0"
gem "solid_queue"
gem "sqlite3", ">= 2.1", group: %i[development test]
gem "stimulus-rails"
gem "turbo-rails"
gem "tzinfo-data", platforms: %i[windows jruby]

# Rich text editing via Action Text + Lexxy (Lexical-based editor)
gem "image_processing", "~> 2.0"
gem "lexxy", "~> 0.9.0"
# image_processing 2.0 made the backends soft dependencies, so the processor
# Active Storage is configured to use has to be declared here explicitly.
# config.active_storage.variant_processor = :vips in all environments, matching
# the libvips already installed in the Docker runtime layer.
gem "ruby-vips"

# SVG icons (Heroicons)
gem "rails_icons"

# Authentication
gem "devise", "~> 5.0"

# Rate limiting and request throttling
gem "rack-attack"

# PDF generation
gem "prawn"

# Error tracking and performance monitoring (production)
gem "sentry-rails"
gem "sentry-ruby"

group :development, :test do
  gem "capybara"
  gem "debug", platforms: %i[mri windows]
  gem "selenium-webdriver"

  # N+1 query detection - helps catch performance issues during development
  gem "bullet"

  # Performance profiling
  gem "rack-mini-profiler", require: false
  gem "stackprof"

  # Code linting and style enforcement
  gem "rubocop", require: false
  gem "rubocop-minitest", require: false
  gem "rubocop-performance", require: false
  gem "rubocop-rails", require: false
end

group :development do
  gem "brakeman"
  gem "web-console"

  # Gem CVE audit. Declared here rather than installed globally so that
  # `bundle exec bundle-audit` resolves through the bundle: the binary on PATH
  # may be a version manager's shim pointing at a different Ruby, in which case
  # the command errors instead of auditing and the check silently stops running.
  gem "bundler-audit", require: false
end
