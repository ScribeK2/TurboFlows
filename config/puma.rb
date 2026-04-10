# Puma Configuration for TurboFlows
# ================================
#
# Production: Uses workers (processes) + threads for horizontal scaling
# Development: Uses threads only for simplicity
#
# Concurrency formula: max_threads * workers = total concurrent requests
# Example: 5 threads * 2 workers = 10 concurrent requests

# Thread pool configuration
# Each worker runs this many threads
max_threads_count = ENV.fetch("RAILS_MAX_THREADS", 5).to_i
min_threads_count = ENV.fetch("RAILS_MIN_THREADS") { max_threads_count }.to_i
threads min_threads_count, max_threads_count

# Port binding
port ENV.fetch("PORT", 3000)

# Environment
environment ENV.fetch("RAILS_ENV", "development")

# PID file for process management
pidfile ENV.fetch("PIDFILE", "tmp/pids/server.pid")

# =============================================================================
# PRODUCTION CONFIGURATION - Workers (processes) for horizontal scaling
# =============================================================================
#
# Workers are forked processes that each run their own thread pool.
# This provides better CPU utilization on multi-core servers.
#
# Recommended WEB_CONCURRENCY values:
# - Render Free/Starter: 2 workers
# - 512MB RAM: 2 workers
# - 1GB RAM: 2-3 workers
# - 2GB+ RAM: 3-4 workers
#
# Note: Workers don't work on JRuby or Windows

if ENV["RAILS_ENV"] == "production"
  # Number of worker processes
  # Default to 2 for most PaaS environments
  workers ENV.fetch("WEB_CONCURRENCY", 2).to_i

  # Preload the application before forking workers
  # This reduces memory usage via Copy-on-Write and speeds up worker boot
  preload_app!

  # Code to run when a worker boots (after fork)
  on_worker_boot do
    # Re-establish database connection after forking
    # Each worker needs its own connection from the pool
    ActiveRecord::Base.establish_connection if defined?(ActiveRecord)

    # Re-establish Redis connection if using ActionCable
    # This ensures each worker has its own Redis connection
    if defined?(ActionCable)
      ActionCable.server.pubsub.send(:redis_connection)
    end
  end

  # Optional: Code to run before a worker forks
  before_fork do
    # Close parent database connections before forking
    ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord)
  end
end

# =============================================================================
# DEVELOPMENT CONFIGURATION
# =============================================================================
# In development, we don't use workers to keep things simple
# and allow better debugging with binding.pry, etc.

# Allow Puma to be restarted by `bin/rails restart`
plugin :tmp_restart

# Run Solid Queue in-process for background job scheduling
plugin :solid_queue

# Logging
if ENV["RAILS_ENV"] == "production"
  # Structured logging in production
  log_requests true

  # Lower keepalive timeout for load balancers (Render, Heroku, etc.)
  # Most load balancers have 30-60 second timeouts
  persistent_timeout 20
end
