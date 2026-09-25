require "test_helper"

class Profiles::ApiTokensControllerTest < ActionDispatch::IntegrationTest
  setup do
    @editor = make_user("editor")
    @csr = make_user("user")
  end

  test "creating a token shows it once in a stream and stores only the digest" do
    sign_in @editor
    post profile_api_tokens_path, params: { api_token: { name: "Claude Code", scopes: %w[read draft], expires_in_days: 30 } },
                                  as: :turbo_stream

    assert_response :success
    raw = response.body[/tf_live_[A-Za-z0-9_-]+/]
    assert raw, "the stream must contain the raw token"
    token = @editor.api_tokens.sole
    assert_equal ApiToken.digest(raw), token.token_digest
    assert_equal %w[read draft], token.scopes

    get edit_profile_path
    assert_not_includes response.body, raw, "the raw token must never render again"
    assert_includes response.body, "Claude Code"
  end

  test "the reveal stream focuses the copy button and describes it with the one-time warning" do
    sign_in @editor
    post profile_api_tokens_path, params: { api_token: { name: "Claude Code", scopes: %w[read], expires_in_days: 30 } },
                                  as: :turbo_stream

    assert_response :success
    assert_select "turbo-stream[action='update'][target='api-token-reveal'] template" do |templates|
      reveal = Nokogiri::HTML.fragment(templates.first.inner_html)
      button = reveal.at_css("button[data-clipboard-target='button']")
      assert button, "expected the reveal card's Copy button"
      assert button.has_attribute?("autofocus"), "the Copy button must carry autofocus"
      assert_equal "api-token-reveal-warning", button["aria-describedby"]
      assert_equal "api-token-reveal-warning", reveal.at_css("#api-token-reveal-warning")&.[]("id")
    end
  end

  test "the reveal card is marked data-turbo-temporary so Back navigation can't resurrect it from cache" do
    sign_in @editor
    post profile_api_tokens_path, params: { api_token: { name: "Claude Code", scopes: %w[read], expires_in_days: 30 } },
                                  as: :turbo_stream

    assert_response :success
    assert_select "turbo-stream[action='update'][target='api-token-reveal'] template" do |templates|
      reveal = Nokogiri::HTML.fragment(templates.first.inner_html)
      assert reveal.element_children.first.has_attribute?("data-turbo-temporary"),
             "the reveal card's outermost element must carry data-turbo-temporary"
    end
  end

  test "a refused create keeps the submitted scopes and expiry, not the defaults" do
    sign_in @editor
    post profile_api_tokens_path,
         params: { api_token: { name: "", scopes: %w[read draft], expires_in_days: 90 } },
         as: :turbo_stream

    assert_response :unprocessable_content
    assert_select "turbo-stream[action='replace'][target='api-token-form'] template" do |templates|
      form = Nokogiri::HTML.fragment(templates.first.inner_html)
      assert form.at_css("#api_token_scope_draft[checked]"), "draft must stay checked on retry"
      assert form.at_css("#api_token_scope_read[checked]"), "read must stay checked on retry"
      selected = form.at_css("select#api_token_expires_in_days option[selected]")
      assert_equal "90", selected["value"]
    end
  end

  test "posting with no scopes ticked is refused with the model's error, not a 500" do
    sign_in @editor
    post profile_api_tokens_path, params: { api_token: { name: "x", expires_in_days: "30" } },
                                  as: :turbo_stream

    assert_response :unprocessable_content
    assert_includes response.body, "must include at least one of"
    assert_equal 0, @editor.api_tokens.count
  end

  test "posting with no expires_in_days is refused, not a 500" do
    sign_in @editor
    post profile_api_tokens_path, params: { api_token: { name: "x", scopes: %w[read] } },
                                  as: :turbo_stream

    assert_response :unprocessable_content
    assert_equal 0, @editor.api_tokens.count
  end

  test "a CSR is not offered the draft scope, and posting it is refused" do
    sign_in @csr
    get edit_profile_path
    assert_select "input[type=checkbox][value=draft]", count: 0

    post profile_api_tokens_path, params: { api_token: { name: "x", scopes: %w[read draft], expires_in_days: 30 } },
                                  as: :turbo_stream
    assert_response :unprocessable_content
    assert_equal 0, @csr.api_tokens.count
  end

  test "revoking a token stops it authenticating" do
    sign_in @editor
    token = ApiToken.issue(user: @editor, name: "x", scopes: %w[read], expires_in_days: 7)
    raw = token.plaintext

    delete profile_api_token_path(token), as: :turbo_stream
    assert_response :success
    assert_nil ApiToken.authenticate(raw)
    assert_includes response.body, "Revoked"
  end

  test "you cannot revoke someone else's token" do
    other = ApiToken.issue(user: @csr, name: "theirs", scopes: %w[read], expires_in_days: 7)
    sign_in @editor
    delete profile_api_token_path(other), as: :turbo_stream
    assert_response :not_found
    assert_equal :active, other.reload.state
  end

  private

  def make_user(role)
    User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                 password_confirmation: "password123!", role: role)
  end
end
