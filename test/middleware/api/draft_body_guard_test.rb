require "test_helper"

class Api::DraftBodyGuardTest < ActiveSupport::TestCase
  setup do
    @downstream_env = nil
    @app = lambda do |env|
      @downstream_env = env
      [200, {}, ["ok"]]
    end
    @guard = Api::DraftBodyGuard.new(@app)
  end

  test "a POST outside /api/v1/drafts is untouched" do
    env = Rack::MockRequest.env_for("/api/v1/workflows", method: "POST", input: "hello")
    status, _headers, body = @guard.call(env)

    assert_equal 200, status
    assert_equal ["ok"], body
    assert_not @downstream_env.key?("action_dispatch.parameter_filter")
  end

  test "a GET to /api/v1/drafts is untouched — the guard is POST-only" do
    env = Rack::MockRequest.env_for("/api/v1/drafts", method: "GET")
    @guard.call(env)

    assert_not @downstream_env.key?("action_dispatch.parameter_filter")
  end

  test "a small drafts POST reaches the app with the parameter filter set" do
    env = Rack::MockRequest.env_for("/api/v1/drafts", method: "POST", input: '{"a":1}')
    status, = @guard.call(env)

    assert_equal 200, status
    assert_equal [/./], @downstream_env["action_dispatch.parameter_filter"]
  end

  test "an oversized drafts POST with no Content-Length is refused, not buffered whole" do
    body = "x" * (WorkflowImporter::MAX_IMPORT_BYTES + 1)
    env = Rack::MockRequest.env_for("/api/v1/drafts", method: "POST", input: body)
    env.delete("CONTENT_LENGTH")

    status, headers, response_body = @guard.call(env)

    assert_equal 413, status
    assert_equal "application/json", headers["content-type"]
    assert_equal "payload_too_large", JSON.parse(response_body.first).dig("errors", 0, "code")
    assert_nil @downstream_env
  end

  test "a drafts POST within the limit but with no Content-Length still reaches the app whole" do
    body = '{"schema_version":"1"}'
    env = Rack::MockRequest.env_for("/api/v1/drafts", method: "POST", input: body)
    env.delete("CONTENT_LENGTH")

    @guard.call(env)

    assert_equal body, @downstream_env["rack.input"].read
  end

  test "MCP_MAX_BYTES tracks WorkflowImporter::MAX_IMPORT_BYTES plus 1 MB, so they can't drift apart" do
    assert_equal WorkflowImporter::MAX_IMPORT_BYTES + 1.megabyte, Api::DraftBodyGuard::MCP_MAX_BYTES
  end

  test "a /mcp POST reaches the app with the parameter filter set" do
    env = Rack::MockRequest.env_for("/mcp", method: "POST", input: '{"jsonrpc":"2.0"}')
    status, = @guard.call(env)

    assert_equal 200, status
    assert_equal [/./], @downstream_env["action_dispatch.parameter_filter"]
  end

  test "a /mcp POST over MCP_MAX_BYTES is refused, not buffered whole" do
    body = "x" * (Api::DraftBodyGuard::MCP_MAX_BYTES + 1)
    env = Rack::MockRequest.env_for("/mcp", method: "POST", input: body)

    status, headers, response_body = @guard.call(env)

    assert_equal 413, status
    assert_equal "application/json", headers["content-type"]
    assert_equal "payload_too_large", JSON.parse(response_body.first).dig("errors", 0, "code")
    assert_nil @downstream_env
  end

  test "a /mcp POST between MAX_IMPORT_BYTES and MCP_MAX_BYTES passes" do
    body = "x" * (WorkflowImporter::MAX_IMPORT_BYTES + 1)
    env = Rack::MockRequest.env_for("/mcp", method: "POST", input: body)

    status, = @guard.call(env)

    assert_equal 200, status
    assert_not_nil @downstream_env
  end
end
