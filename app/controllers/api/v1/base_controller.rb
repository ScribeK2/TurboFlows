module Api
  module V1
    # Every /api/v1 controller inherits this. ActionController::API, not
    # ApplicationController: no session, no cookies, no CSRF, so a browser's
    # session cookie can never authenticate an API request. Only a bearer token
    # can (spec 2026-09-25-api-and-mcp-design §2).
    class BaseController < ActionController::API
      # Params are never wrapped: the draft endpoints read the raw body, and
      # wrapping would parse it first and turn malformed JSON into a 400 before
      # the validator could name the problem.
      wrap_parameters false

      before_action :authenticate_token!

      rescue_from ActiveRecord::RecordNotFound do
        render_error(:not_found, code: "not_found", message: "No workflow with that id is visible to this token.")
      end

      attr_reader :current_user, :current_api_token

      private

      def authenticate_token!
        @current_api_token = ApiToken.authenticate(ApiToken.raw_from_authorization(request.authorization))

        unless @current_api_token
          response.headers["WWW-Authenticate"] = 'Bearer realm="TurboFlows"'
          return render_error(:unauthorized, code: "unauthorized",
                                             message: "Send a valid, unexpired TurboFlows API token as " \
                                                      "'Authorization: Bearer tf_live_…'.")
        end

        @current_user = @current_api_token.user
        @current_api_token.record_use!
      end

      def require_scope!(scope)
        return if current_api_token.allows?(scope)

        render_error(:forbidden, code: "insufficient_scope",
                                 message: "This token doesn't have the #{scope} scope, or your role no longer allows it.")
      end

      def render_error(status, code:, message:, path: nil)
        render_errors(status, [{ path:, code:, message: }])
      end

      def render_errors(status, errors, warnings: nil)
        body = { errors: }
        body[:warnings] = warnings if warnings
        render json: body, status:
      end
    end
  end
end
