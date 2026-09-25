require "stringio"

module Api
  # Sits in front of everything that would otherwise touch a drafts POST body,
  # including ActionController::API's Instrumentation — which builds
  # request.filtered_parameters (and therefore JSON-parses the whole body) for
  # the "start_processing.action_controller" event before any controller
  # callback runs. A before_action in DraftsController, such as the
  # refuse_oversized_body! this replaced, always runs too late: the parse (and
  # the unfiltered log line) has already happened by the time it fires.
  #
  # Two jobs, in this order, for any POST whose path starts with
  # /api/v1/drafts (both /api/v1/drafts and /api/v1/drafts/validate):
  #
  #   1. Refuse a body over WorkflowImporter::MAX_IMPORT_BYTES with a 413.
  #      Nothing downstream ever parses it.
  #   2. Otherwise, set action_dispatch.parameter_filter so every parameter key
  #      is masked in the log. A document's title, instructions and tags have
  #      no business at :info in production (config/environments/production.rb),
  #      and config/initializers/filter_parameter_logging.rb only lists
  #      known-sensitive field NAMES — none of which this dialect's keys match,
  #      and a fixed list would drift the moment a field is added.
  class DraftBodyGuard
    def initialize(app)
      @app = app
    end

    def call(env)
      request = Rack::Request.new(env)
      return @app.call(env) unless guarded?(request)
      return too_large if content_length(env) > WorkflowImporter::MAX_IMPORT_BYTES

      env["action_dispatch.parameter_filter"] = [/./]
      @app.call(env)
    end

    private

    def guarded?(request)
      request.post? && request.path.start_with?("/api/v1/drafts")
    end

    # CONTENT_LENGTH is trusted when present and nonzero. Otherwise (absent, or
    # zero on a chunked request) the only way to know the size is to read the
    # body — up to one byte past the limit, enough to answer "over or not"
    # without buffering an arbitrarily large upload. Reading that far consumes
    # rack.input, so it is replaced with exactly what was read, so the app
    # still sees the same, whole body afterwards.
    def content_length(env)
      declared = env["CONTENT_LENGTH"].to_i
      return declared if declared.positive?

      chunk = env["rack.input"].read(WorkflowImporter::MAX_IMPORT_BYTES + 1).to_s
      env["rack.input"] = StringIO.new(chunk)
      env["CONTENT_LENGTH"] = chunk.bytesize.to_s
      chunk.bytesize
    end

    def too_large
      body = JSON.generate(
        errors: [{ path: nil, code: "payload_too_large",
                   message: "The document is over #{WorkflowImporter::MAX_IMPORT_BYTES / 1.megabyte} MB." }]
      )
      [Rack::Utils::SYMBOL_TO_STATUS_CODE[:content_too_large], { "content-type" => "application/json" }, [body]]
    end
  end
end
