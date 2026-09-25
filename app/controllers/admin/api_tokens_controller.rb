module Admin
  # Every API token in the install, with a revoke button (spec
  # 2026-09-25-api-and-mcp-design §1). Revoking is the admin's answer to a
  # leaked or forgotten token: its owner keeps the account, and the token stops
  # at once.
  class ApiTokensController < BaseController
    def index
      @tokens = ApiToken.includes(:user).order(Arel.sql("revoked_at IS NOT NULL"), expires_at: :desc)
    end

    def destroy
      @token = ApiToken.find(params[:id])
      @token.revoke! if @token.state == :active
      render turbo_stream: turbo_stream.replace(@token, partial: "admin/api_tokens/row", locals: { token: @token })
    end
  end
end
