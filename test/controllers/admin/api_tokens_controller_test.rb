require "test_helper"

class Admin::ApiTokensControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = make_user("admin")
    @editor = make_user("editor")
    @token = ApiToken.issue(user: @editor, name: "Editor laptop", scopes: %w[read draft], expires_in_days: 30)
  end

  test "an admin sees every token with its owner, scopes and state" do
    sign_in @admin
    get admin_api_tokens_path
    assert_response :success
    assert_select "td", text: /Editor laptop/
    assert_includes response.body, @editor.email
    assert_select "[aria-current='page']", text: /API tokens/
  end

  test "an admin's revoke stops the token at once" do
    raw = @token.plaintext
    sign_in @admin
    delete admin_api_token_path(@token), as: :turbo_stream
    assert_response :success
    assert_nil ApiToken.authenticate(raw)
    assert_includes response.body, "Revoked"
  end

  test "an editor and a CSR are refused like every other admin page" do
    [@editor, make_user("user")].each do |user|
      sign_in user
      get admin_api_tokens_path
      assert_not_equal 200, response.status, "#{user.role} must not see the list"
      delete admin_api_token_path(@token)
      assert_equal :active, @token.reload.state
    end
  end

  private

  def make_user(role)
    User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                 password_confirmation: "password123!", role: role)
  end
end
