# Gemfile
source "https://rubygems.org"

ruby "4.0.1"

gem "bootsnap", ">= 1.4.4", require: false
gem "csv"
gem "importmap-rails"
gem "propshaft"
gem "puma", ">= 5.0"
gem "rails", "~> 8.1.0"
gem "sqlite3", ">= 2.1"

# Solid stack: SQLite-backed replacements for Redis (cache, cable, queue)
gem "solid_cache"
gem "solid_cable"
gem "solid_queue"
gem "stimulus-rails"
gem "turbo-rails"
gem "tzinfo-data", platforms: %i[mingw mswin x64_mingw jruby]

# Rich text editing via Action Text + Lexxy (Lexical-based editor)
gem "image_processing", "~> 1.2"
gem "lexxy", "~> 0.8.0.beta"

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
  gem "debug", platforms: %i[mri mingw x64_mingw]
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
end
