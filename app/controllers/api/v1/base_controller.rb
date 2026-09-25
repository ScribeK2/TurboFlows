module Api
  module V1
    # Every /api/v1 controller inherits this. ActionController::API, not
    # ApplicationController: no session, no cookies, no CSRF, so a browser's
    # session cookie can never authenticate an API request. Only a bearer token
    # can (spec 2026-09-25-api-and-mcp-design §2).
    class BaseController < ActionController::API
      include Api::TokenAuthentication

      # Params are never wrapped. Wrapping wouldn't turn malformed JSON into an
      # uncaught 400 either way: ParamsWrapper itself skips wrapping when the
      # body doesn't parse, and the rescue_from below turns that parse error
      # into this API's malformed_json shape regardless. This line stays as a
      # guarantee that the drafts path reads only request.raw_post, never
      # params, so a change nearby can't quietly start reading the wrapped
      # (and therefore pre-parsed) hash.
      wrap_parameters false

      rescue_from ActiveRecord::RecordNotFound do
        render_error(:not_found, code: "not_found", message: "No workflow with that id is visible to this token.")
      end

      rescue_from ActionDispatch::Http::Parameters::ParseError do
        render_error(:bad_request, code: "malformed_json", message: "The request body is not valid JSON.")
      end

      private

      def draft_submission
        Api::DraftSubmission.new(user: current_user, api_token: current_api_token, content: request.raw_post)
      end
    end
  end
end
