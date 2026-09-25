require "test_helper"

# Drives tools through the real wire: Api::Mcp::ServerFactory.build and
# MCP::Server#handle, not a direct Tool.call. A schema violation (an unknown
# status, a non-numeric page, an unknown argument) never reaches tool code: the
# SDK's own input_schema gate answers it first, as a tool result with isError
# true and a text-only content block naming the offending argument -- never a
# JSON-RPC error (spec 2026-09-25-api-and-mcp-design §3, amended to accept the
# SDK's text-only refusal for schema violations).
class Api::Mcp::ServerWireTest < ActiveSupport::TestCase
  setup do
    @editor = User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @token = ApiToken.issue(user: @editor, name: "wire", scopes: %w[read], expires_in_days: 7)
    @server = Api::Mcp::ServerFactory.build(user: @editor, api_token: @token, base_url: "http://example.test")
    @mine = Workflow.create!(title: "Refund dispute #{SecureRandom.hex(2)}", user: @editor, status: "draft")
  end

  test "search_workflows over the wire returns structured content for a matching query" do
    result = call("search_workflows", query: "refund")
    assert_not result[:isError]
    assert_equal [@mine.id], result[:structuredContent][:workflows].pluck(:id)
  end

  test "search_workflows refuses an unknown status as a text-only tool result, not a JSON-RPC error" do
    assert_schema_refusal call_raw("search_workflows", status: "archived"), /status/
  end

  test "search_workflows refuses a non-numeric page as a text-only tool result, not a JSON-RPC error" do
    assert_schema_refusal call_raw("search_workflows", page: "two"), /page/
  end

  test "search_workflows refuses a status sent as a number as a text-only tool result, not a JSON-RPC error" do
    assert_schema_refusal call_raw("search_workflows", status: 5), /status/
  end

  test "search_workflows refuses an unknown argument as a text-only tool result, not a JSON-RPC error" do
    assert_schema_refusal call_raw("search_workflows", q: "x"), /q/
  end

  test "get_authoring_guide refuses an unknown argument as a text-only tool result, not a JSON-RPC error" do
    assert_schema_refusal call_raw("get_authoring_guide", foo: 1), /foo/
  end

  test "get_workflow refuses a missing id as a text-only tool result, not a JSON-RPC error" do
    assert_schema_refusal call_raw("get_workflow", {}), /id/
  end

  test "create_workflow_draft over the wire with a valid document creates a draft and returns its url" do
    result = call_with_draft_token("create_workflow_draft", document: valid_document)
    assert_not result[:isError]
    created = result[:structuredContent][:workflows].sole
    assert_equal "http://example.test/workflows/#{created[:id]}", created[:url]
  end

  test "create_workflow_draft over the wire treats a document sent as a JSON string the same as the object" do
    result = call_with_draft_token("create_workflow_draft", document: JSON.generate(valid_document))
    assert_not result[:isError]
    created = result[:structuredContent][:workflows].sole
    assert_equal "http://example.test/workflows/#{created[:id]}", created[:url]
  end

  private

  def call(name, arguments)
    call_raw(name, arguments).fetch(:result)
  end

  def call_raw(name, arguments)
    @server.handle({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } })
  end

  def call_with_draft_token(name, arguments)
    token = ApiToken.issue(user: @editor, name: "wire-draft", scopes: %w[read draft], expires_in_days: 7)
    server = Api::Mcp::ServerFactory.build(user: @editor, api_token: token, base_url: "http://example.test")
    server.handle({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } })
          .fetch(:result)
  end

  def valid_document
    { schema_version: "1", workflows: [{ title: "Wire draft #{SecureRandom.hex(2)}",
                                         steps: [{ id: "done", type: "resolve", title: "Done",
                                                   resolution_type: "success" }] }] }
  end

  def assert_schema_refusal(response, argument_pattern)
    assert_not response.key?(:error), "expected a tool result, not a JSON-RPC error: #{response.inspect}"
    result = response.fetch(:result)
    assert result[:isError], "expected isError true: #{result.inspect}"
    assert_match argument_pattern, result[:content].first[:text]
  end
end
