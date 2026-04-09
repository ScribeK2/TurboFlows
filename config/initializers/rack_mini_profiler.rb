if defined?(Rack::MiniProfiler) && Rails.env.development?
  require "rack-mini-profiler"
  require "stackprof"

  Rack::MiniProfiler.config.storage = Rack::MiniProfiler::MemoryStore
  Rack::MiniProfiler.config.position = "bottom-right"
  Rack::MiniProfiler.config.enable_advanced_debugging_tools = true
  Rack::MiniProfiler.config.skip_paths = %w[/cable /assets]
end
