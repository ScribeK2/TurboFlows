require "stringio"

module Api
  # Sits in front of everything that would otherwise touch a drafts POST body,
  # including ActionController::API's Instrumentation — which builds
  # request.filtered_parameters (and therefore JSON-parses the whole body) for
  # the "start_processing.action_controller" event before any controller
  # callback runs. A before_action in DraftsController, such as the
  # refuse_oversized_body! this replaced, always runs too late: the parse (and
  # the unfiltered log line) has already happened by the time it fires. The
  # same is true of /mcp (spec 2026-09-25-api-and-mcp-design §3): a
  # tools/call's arguments carry the same documents /api/v1/drafts does, read
  # by the same instrumentation before McpController#handle runs.
  #
  # Two jobs, in this order, for any POST whose path starts with
  # /api/v1/drafts (both /api/v1/drafts and /api/v1/drafts/validate) or is
  # exactly /mcp:
  #
  #   1. Refuse a body over the path's limit (WorkflowImporter::MAX_IMPORT_BYTES
  #      for drafts, MCP_MAX_BYTES for /mcp) with a 413. Nothing downstream
  #      ever parses it.
  #   2. Otherwise, set action_dispatch.parameter_filter so every parameter key
  #      is masked in the log. A document's title, instructions and tags have
  #      no business at :info in production (config/environments/production.rb),
  #      and config/initializers/filter_parameter_logging.rb only lists
  #      known-sensitive field NAMES — none of which this dialect's keys match,
  #      and a fixed list would drift the moment a field is added.
  class DraftBodyGuard
    # WorkflowImporter::MAX_IMPORT_BYTES plus 1 MB for the JSON-RPC wrapping
    # (envelope, tool name, arguments key). Written as a literal, not derived
    # from WorkflowImporter::MAX_IMPORT_BYTES, because this file loads via
    # require_relative in config/application.rb before autoloading is set up —
    # WorkflowImporter isn't a resolvable constant yet.
    MCP_MAX_BYTES = 11.megabytes

    def initialize(app)
      @app = app
    end

    def call(env)
      request = Rack::Request.new(env)
      return @app.call(env) unless guarded?(request)

      limit = mcp_path?(request) ? MCP_MAX_BYTES : WorkflowImporter::MAX_IMPORT_BYTES
      return too_large(limit) if content_length(env, limit) > limit

      env["action_dispatch.parameter_filter"] = [/./]
      @app.call(env)
    end

    private

    def guarded?(request)
      request.post? && (request.path.start_with?("/api/v1/drafts") || mcp_path?(request))
    end

    # The route (config/routes.rb) answers /mcp, /mcp/ (the router ignores a
    # trailing slash) and, absent format: false, /mcp.json — any path the
    # router treats as this endpoint must be treated as it here too, or a body
    # of any size reaches JSON parsing (and the log) unguarded.
    def mcp_path?(request)
      request.path.chomp("/") == "/mcp"
    end

    # CONTENT_LENGTH is trusted when present and nonzero. Otherwise (absent, or
    # zero on a chunked request) the only way to know the size is to read the
    # body — up to one byte past the limit, enough to answer "over or not"
    # without buffering an arbitrarily large upload. Reading that far consumes
    # rack.input, so it is replaced with exactly what was read, so the app
    # still sees the same, whole body afterwards.
    def content_length(env, limit)
      declared = env["CONTENT_LENGTH"].to_i
      return declared if declared.positive?

      chunk = env["rack.input"].read(limit + 1).to_s
      env["rack.input"] = StringIO.new(chunk)
      env["CONTENT_LENGTH"] = chunk.bytesize.to_s
      chunk.bytesize
    end

    def too_large(limit)
      body = JSON.generate(
        errors: [{ path: nil, code: "payload_too_large",
                   message: "The document is over #{limit / 1.megabyte} MB." }]
      )
      [Rack::Utils::SYMBOL_TO_STATUS_CODE[:content_too_large], { "content-type" => "application/json" }, [body]]
    end
  end
end
