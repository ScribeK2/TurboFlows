require "test_helper"

class Api::Mcp::ServerFactoryTest < ActiveSupport::TestCase
  setup do
    @editor = make_user("editor")
  end

  test "a read token lists only the read tools" do
    token = ApiToken.issue(user: @editor, name: "r", scopes: %w[read], expires_in_days: 7)
    assert_equal %w[get_authoring_guide get_workflow search_workflows], tool_names(token)
  end

  test "a read+draft token lists all five" do
    token = ApiToken.issue(user: @editor, name: "d", scopes: %w[read draft], expires_in_days: 7)
    assert_equal %w[create_workflow_draft get_authoring_guide get_workflow search_workflows validate_workflow_draft],
                 tool_names(token)
  end

  test "a demoted editor's draft token lists only the read tools" do
    token = ApiToken.issue(user: @editor, name: "d", scopes: %w[read draft], expires_in_days: 7)
    @editor.update!(role: "user")
    assert_equal %w[get_authoring_guide get_workflow search_workflows], tool_names(token.reload)
  end

  test "a draft-only token lists only the draft tools" do
    token = ApiToken.issue(user: @editor, name: "d", scopes: %w[draft], expires_in_days: 7)
    assert_equal %w[create_workflow_draft validate_workflow_draft], tool_names(token)
  end

  private

  def tool_names(token)
    server = Api::Mcp::ServerFactory.build(user: token.user, api_token: token, base_url: "http://example.test")
    server.tools.keys.map(&:to_s).sort
  end

  def make_user(role)
    User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                 password_confirmation: "password123!", role: role)
  end
end
