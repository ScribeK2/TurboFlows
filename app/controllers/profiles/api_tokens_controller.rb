module Profiles
  # Create and revoke the signed-in person's own API tokens. The raw token is
  # answered in a stream, never the flash: the flash rides in the session cookie.
  class ApiTokensController < ApplicationController
    before_action :authenticate_user!

    def create
      token = ApiToken.issue(user: current_user, **token_params)

      if token.persisted?
        render turbo_stream: [
          turbo_stream.update("api-token-reveal", partial: "profiles/api_tokens/reveal", locals: { token: }),
          turbo_stream.replace("api-token-form", partial: "profiles/api_tokens/form", locals: { token: nil }),
          list_stream
        ]
      else
        render turbo_stream: turbo_stream.replace("api-token-form", partial: "profiles/api_tokens/form",
                                                                    locals: { token: }),
               status: :unprocessable_content
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
