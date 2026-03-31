# Puma Configuration for TurboFlows
# ================================
#
# Production: Uses workers (processes) + threads for horizontal scaling
# Development: Uses threads only for simplicity
#
# Concurrency formula: max_threads * workers = total concurrent requests
# Example: 5 threads * 2 workers = 10 concurrent requests

# Thread pool configuration
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
# PRODUCTION CONFIGURATION
# =============================================================================
if ENV["RAILS_ENV"] == "production"
  # NUM_CPUS provided by ONCE, WEB_CONCURRENCY as fallback
  workers ENV.fetch("NUM_CPUS", ENV.fetch("WEB_CONCURRENCY", 2)).to_i

  # Preload the application before forking workers
  preload_app!

  # Re-establish database connection after forking
  on_worker_boot do
    ActiveRecord::Base.establish_connection if defined?(ActiveRecord)
  end

  # Close parent database connections before forking
  before_fork do
    ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord)
  end
end

# =============================================================================
# DEVELOPMENT CONFIGURATION
# =============================================================================
# Allow Puma to be restarted by `bin/rails restart`
plugin :tmp_restart

# ONCE runs Solid Queue as a separate process via Procfile/bin/boot,
# so we do NOT use `plugin :solid_queue` here.

if ENV["RAILS_ENV"] == "production"
  log_requests true
  persistent_timeout 20
end
