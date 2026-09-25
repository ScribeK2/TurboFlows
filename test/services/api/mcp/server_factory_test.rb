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

  test "a draft-only token lists the draft tools plus the authoring guide" do
    token = ApiToken.issue(user: @editor, name: "d", scopes: %w[draft], expires_in_days: 7)
    assert_equal %w[create_workflow_draft get_authoring_guide validate_workflow_draft], tool_names(token)
  end

  test "report_exception sends Rails.error only the JSON-RPC method and tool name, never arguments" do
    secret = "TOP SECRET DRAFT DOCUMENT CONTENTS #{SecureRandom.hex(4)}"
    request = { jsonrpc: "2.0", id: 1, method: "tools/call",
                params: { name: "create_workflow_draft", arguments: { document: secret } } }

    report = assert_error_reported(RuntimeError) do
      Api::Mcp::ServerFactory.report_exception(RuntimeError.new("boom"), { request: request })
    end

    assert_not_includes report.context.inspect, secret
    assert_equal "tools/call", report.context.dig(:mcp, :method)
    assert_equal "create_workflow_draft", report.context.dig(:mcp, :tool)
  end

  test "report_exception tolerates JSON-RPC positional (array) params without raising" do
    request = { jsonrpc: "2.0", id: 1, method: "tools/call", params: %w[not a hash] }

    report = assert_error_reported(RuntimeError) do
      Api::Mcp::ServerFactory.report_exception(RuntimeError.new("boom"), { request: request })
    end

    assert_equal "tools/call", report.context.dig(:mcp, :method)
    assert_nil report.context.dig(:mcp, :tool)
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
