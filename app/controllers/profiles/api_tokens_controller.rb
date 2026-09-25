module Profiles
  # Create and revoke the signed-in person's own API tokens. The raw token is
  # answered in a stream, never the flash: the flash rides in the session cookie.
  class ApiTokensController < ApplicationController
    before_action :authenticate_user!

    def create
      attrs = token_params
      token = ApiToken.issue(user: current_user, name: attrs[:name], scopes: attrs[:scopes],
                             expires_in_days: attrs[:expires_in_days])

      if token.persisted?
        # The old form's submit button is what's focused when this arrives, so it
        # has to be destroyed BEFORE the reveal is inserted: autofocus only takes
        # over from nothing, not from something already focused (spec 2026-09-25
        # ruling on the profile-page tokens review).
        render turbo_stream: [
          turbo_stream.replace("api-token-form", partial: "profiles/api_tokens/form", locals: { token: nil }),
          list_stream,
          turbo_stream.update("api-token-reveal", partial: "profiles/api_tokens/reveal", locals: { token: })
        ]
      else
        locals = { token:, submitted_expires_in_days: attrs[:expires_in_days] }
        stream = turbo_stream.replace("api-token-form", partial: "profiles/api_tokens/form", locals:)
        render turbo_stream: stream, status: :unprocessable_content
      end
    end

    def destroy
      current_user.api_tokens.find(params[:id]).revoke!
      render turbo_stream: [turbo_stream.update("api-token-reveal", ""), list_stream]
    end

    private

    def token_params
      params.expect(api_token: [:name, :expires_in_days, { scopes: [] }]).to_h.symbolize_keys
    end

    def list_stream
      turbo_stream.replace("api-tokens-list", partial: "profiles/api_tokens/list",
                                              locals: { tokens: current_user.api_tokens.order(created_at: :desc) })
    end
  end
end
