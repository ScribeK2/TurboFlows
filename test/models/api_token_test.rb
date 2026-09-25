require "test_helper"

class ApiTokenTest < ActiveSupport::TestCase
  setup do
    @editor = make_user("editor")
    @csr = make_user("user")
  end

  test "issue returns the raw token once and stores only its digest" do
    token = ApiToken.issue(user: @editor, name: "Laptop", scopes: %w[read draft], expires_in_days: 30)

    assert_predicate token, :persisted?
    assert token.plaintext.start_with?("tf_live_")
    assert_equal ApiToken.digest(token.plaintext), token.token_digest
    assert_nil ApiToken.find(token.id).plaintext
    assert_not ApiToken.exists?(token_digest: token.plaintext)
  end

  test "expiry is required and capped at 90 days" do
    assert_not ApiToken.issue(user: @editor, name: "x", scopes: %w[read], expires_in_days: nil).persisted?
    assert_not ApiToken.issue(user: @editor, name: "x", scopes: %w[read], expires_in_days: 91).persisted?
    assert_predicate ApiToken.issue(user: @editor, name: "x", scopes: %w[read], expires_in_days: 90), :persisted?
  end

  test "scopes must be known and non-empty" do
    assert_not ApiToken.issue(user: @editor, name: "x", scopes: [], expires_in_days: 30).persisted?
    assert_not ApiToken.issue(user: @editor, name: "x", scopes: %w[publish], expires_in_days: 30).persisted?
  end

  test "a CSR cannot be issued the draft scope" do
    token = ApiToken.issue(user: @csr, name: "x", scopes: %w[read draft], expires_in_days: 30)
    assert_not token.persisted?
    assert_includes token.errors[:scopes].join, "draft"
  end

  test "authenticate finds an active token and refuses revoked, expired, unknown and unprefixed ones" do
    token = ApiToken.issue(user: @editor, name: "x", scopes: %w[read], expires_in_days: 7)
    raw = token.plaintext

    assert_equal token, ApiToken.authenticate(raw)
    assert_nil ApiToken.authenticate("tf_live_nope")
    assert_nil ApiToken.authenticate(raw.delete_prefix("tf_live_"))
    assert_nil ApiToken.authenticate(nil)

    travel_to(token.expires_at - 1.second) { assert_equal token, ApiToken.authenticate(raw) }
    travel_to(token.expires_at + 1.second) { assert_nil ApiToken.authenticate(raw) }

    token.revoke!
    assert_nil ApiToken.authenticate(raw)
  end

  test "authenticate refuses a token whose user is deactivated" do
    token = ApiToken.issue(user: @editor, name: "x", scopes: %w[read], expires_in_days: 7)
    @editor.update!(deactivated_at: Time.current)
    assert_nil ApiToken.authenticate(token.plaintext)
  end

  test "the draft scope follows the user's current role" do
    token = ApiToken.issue(user: @editor, name: "x", scopes: %w[read draft], expires_in_days: 7)
    assert token.allows?(:draft)

    @editor.update!(role: "user")
    token.reload
    assert_not token.allows?(:draft)
    assert token.allows?(:read)
    assert_equal %w[read], token.effective_scopes
  end

  test "record_use! writes last_used_at at most once a minute" do
    token = ApiToken.issue(user: @editor, name: "x", scopes: %w[read], expires_in_days: 7)
    token.record_use!
    first = token.reload.last_used_at
    assert first

    travel 30.seconds do
      token.record_use!
      assert_equal first, token.reload.last_used_at
    end
    travel 61.seconds do
      token.record_use!
      assert_operator token.reload.last_used_at, :>, first
    end
  end

  test "raw_from_authorization reads a Bearer header in any case and nothing else" do
    assert_equal "tf_live_abc", ApiToken.raw_from_authorization("Bearer tf_live_abc")
    assert_equal "tf_live_abc", ApiToken.raw_from_authorization("bearer   tf_live_abc")
    assert_nil ApiToken.raw_from_authorization("Basic dXNlcjpwYXNz")
    assert_nil ApiToken.raw_from_authorization("Bearer")
    assert_nil ApiToken.raw_from_authorization(nil)
  end

  private

  def make_user(role)
    User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                 password_confirmation: "password123!", role: role)
  end
end
