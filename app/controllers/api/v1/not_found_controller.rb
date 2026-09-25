module Api
  module V1
    # The catch-all under /api. No token needed: a wrong URL is a 404 whoever
    # asks, and answering 401 would suggest the path exists.
    #
    # ActionController::Metal, not ::API: a POST to a mistyped path (an
    # editor reaching for /api/v1/drafts and missing) still carries the same
    # draft document a real request would, and ActionController::API's
    # Instrumentation builds request.filtered_parameters — which parses the
    # body — before any action runs (config/routes.rb's catch-all comment;
    # Api::DraftBodyGuard's header explains the same mechanism for /mcp and
    # /api/v1/drafts). DraftBodyGuard only masks those two paths, so a typo'd
    # path landing here would otherwise log a document's contents unfiltered
    # at :info in production. Metal skips Instrumentation entirely: this
    # action never touches params, so nothing is ever parsed or logged.
    class NotFoundController < ActionController::Metal
      def show
        self.status = :not_found
        self.content_type = "application/json"
        self.response_body = JSON.generate(
          errors: [{ path: nil, code: "not_found", message: "No API endpoint at #{request.path}." }]
        )
      end
    end
  end
end
