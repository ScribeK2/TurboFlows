module Api
  # Bearer-token authentication for every token-only endpoint: /api/v1 and
  # /mcp (spec 2026-09-25-api-and-mcp-design §1-§3). Include it in an
  # ActionController::API subclass, never in ApplicationController: a session
  # cookie must never authenticate these.
  module TokenAuthentication
    extend ActiveSupport::Concern

    included do
      before_action :authenticate_token!
      attr_reader :current_user, :current_api_token
    end

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
