require "test_helper"

class McpTest < ActionDispatch::IntegrationTest
  setup do
    @editor = User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @reader = ApiToken.issue(user: @editor, name: "r", scopes: %w[read], expires_in_days: 7)
    @drafter = ApiToken.issue(user: @editor, name: "d", scopes: %w[read draft], expires_in_days: 7)
  end

  test "initialize answers with the server's name and instructions" do
    result = rpc(@drafter, "initialize", protocolVersion: "2025-06-18", capabilities: {},
                                         clientInfo: { name: "test", version: "0" })
    assert_equal "turboflows", result.dig("serverInfo", "name")
    assert_match(/get_authoring_guide/, result["instructions"])
  end

  test "tools/list follows the token's scopes" do
    assert_equal 3, rpc(@reader, "tools/list")["tools"].size
    assert_equal 5, rpc(@drafter, "tools/list")["tools"].size
  end

  test "a read token calling create_workflow_draft anyway writes nothing" do
    assert_no_difference("Workflow.count") do
      post mcp_path, params: envelope("tools/call", name: "create_workflow_draft",
                                                    arguments: { document: valid_document }),
                     headers: headers(@reader)
    end
    body = parse(response)
    # The tool is filtered out of this token's tools/list (server_factory_test), so the SDK
    # itself refuses the call before any tool code runs: JSON-RPC Invalid params (-32602),
    # "Tool not found". Anything else -- in particular -32603 Internal error -- means
    # Api::Mcp::ServerFactory.report_exception raised while handling the refusal and replaced
    # the real error (server_factory_test covers the reporter directly).
    assert_equal(-32_602, body.dig("error", "code"), "expected Invalid params: #{body.inspect}")
    assert_match(/Tool not found/, (body.dig("error", "data") || body.dig("error", "message")).to_s)
  end

  test "an unhandled exception over the real HTTP path is reported once, naming the method and tool, never the request" do
    original_find = Api::WorkflowCatalog.instance_method(:find)
    Api::WorkflowCatalog.define_method(:find) { |*| raise "catalog boom" }

    reports = capture_error_reports(RuntimeError) do
      post mcp_path, params: envelope("tools/call", name: "get_workflow", arguments: { id: 999_999 }),
                     headers: headers(@reader)
    end

    assert_equal 1, reports.size, "expected exactly one Rails.error report: #{reports.inspect}"
    report = reports.first
    assert_equal "tools/call", report.context.dig(:mcp, :method)
    assert_equal "get_workflow", report.context.dig(:mcp, :tool)
    assert_not_includes report.context.inspect, "999999"
    assert_not_includes report.context.inspect, "arguments"
    assert_operator response.status, :<, 500
  ensure
    Api::WorkflowCatalog.define_method(:find, original_find)
  end

  test "the whole loop: refused with a finding, fixed, created" do
    refused = rpc(@drafter, "tools/call", name: "create_workflow_draft", arguments: { document: dangling_document })
    assert refused["isError"]
    assert_equal "dangling_transition_target", refused.dig("structuredContent", "errors", 0, "code")

    fixed = dangling_document
    fixed[:workflows][0][:steps][0][:transitions][0][:target_id] = "done"
    created = rpc(@drafter, "tools/call", name: "create_workflow_draft", arguments: { document: fixed })
    assert_not created["isError"]
    workflow = Workflow.find(created.dig("structuredContent", "workflows", 0, "id"))
    assert_equal @drafter, workflow.api_token
  end

  test "a notification's 202 ack has no text/html content type" do
    notification = { jsonrpc: "2.0", method: "notifications/initialized" }.to_json
    post mcp_path, params: notification, headers: headers(@drafter)
    assert_response :accepted
    assert_not_equal "text/html", response.media_type
  end

  test "a wrong argument type is a tool error the model can read, not a 500" do
    result = rpc(@reader, "tools/call", name: "search_workflows", arguments: { page: "two" })
    assert result["isError"], "expected isError true: #{result.inspect}"
  end

  test "no token, a bad token, or only a session is a 401 with WWW-Authenticate" do
    post mcp_path, params: envelope("tools/list"), headers: base_headers
    assert_response :unauthorized
    assert_match(/Bearer/, response.headers["WWW-Authenticate"])

    post mcp_path, params: envelope("tools/list"), headers: base_headers.merge("Authorization" => "Bearer tf_live_x")
    assert_response :unauthorized

    sign_in @editor
    post mcp_path, params: envelope("tools/list"), headers: base_headers
    assert_response :unauthorized
  end

  test "GET /mcp in stateless mode is exactly 405" do
    get mcp_path, headers: headers(@reader).merge("Accept" => "text/event-stream")
    assert_response :method_not_allowed
  end

  test "a tools/call body over the cap is a 413 before anything parses it" do
    huge = { schema_version: "1", workflows: [{ title: "Huge", description: "x" * Api::DraftBodyGuard::MCP_MAX_BYTES,
                                                steps: [] }] }
    assert_no_difference("Workflow.count") do
      post mcp_path, params: envelope("tools/call", name: "create_workflow_draft", arguments: { document: huge }),
                     headers: headers(@drafter)
    end
    assert_response :content_too_large
    assert_equal "payload_too_large", response.parsed_body.dig("errors", 0, "code")
  end

  test "the log never carries a document sent over MCP" do
    title = "Secret policy #{SecureRandom.hex(4)}"
    document = valid_document.tap { it[:workflows][0][:title] = title }
    logged = nil
    subscriber = ->(*, payload) { logged = payload[:params] }
    ActiveSupport::Notifications.subscribed(subscriber, "start_processing.action_controller") do
      rpc(@drafter, "tools/call", name: "create_workflow_draft", arguments: { document: })
    end
    assert_not_includes logged.to_s, title
    assert_includes logged.to_s, "[FILTERED]"
  end

  # The route answers /mcp/ too (the router ignores a trailing slash), so the
  # body guard has to recognize it as the same endpoint — otherwise the whole
  # document reaches this log line unfiltered.
  test "the log never carries a document sent over MCP, at /mcp/ either" do
    title = "Secret policy #{SecureRandom.hex(4)}"
    document = valid_document.tap { it[:workflows][0][:title] = title }
    logged = nil
    subscriber = ->(*, payload) { logged = payload[:params] }
    ActiveSupport::Notifications.subscribed(subscriber, "start_processing.action_controller") do
      post "/mcp/", params: envelope("tools/call", name: "create_workflow_draft", arguments: { document: }),
                    headers: headers(@drafter)
      assert_response :success
    end
    assert_not_includes logged.to_s, title
    assert_includes logged.to_s, "[FILTERED]"
  end

  test "POST /mcp.json does not reach the controller" do
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/mcp.json", method: :post)
    end
  end

  # /mcp answers DELETE too (config/routes.rb); the guard must filter and cap
  # every method on this path, not just POST (Api::DraftBodyGuard#guarded?).
  test "the log never carries a document sent over MCP, over DELETE either" do
    title = "Secret policy #{SecureRandom.hex(4)}"
    document = valid_document.tap { it[:workflows][0][:title] = title }
    logged = nil
    subscriber = ->(*, payload) { logged = payload[:params] }
    ActiveSupport::Notifications.subscribed(subscriber, "start_processing.action_controller") do
      delete mcp_path, params: envelope("tools/call", name: "create_workflow_draft", arguments: { document: }),
                       headers: headers(@drafter)
    end
    assert_not_includes logged.to_s, title
    assert_includes logged.to_s, "[FILTERED]"
  end

  # The router squeezes a doubled slash down to one before matching a route,
  # so /mcp// still resolves to mcp#handle — the guard has to agree.
  test "the log never carries a document sent over MCP, at /mcp// either" do
    title = "Secret policy #{SecureRandom.hex(4)}"
    document = valid_document.tap { it[:workflows][0][:title] = title }
    logged = nil
    subscriber = ->(*, payload) { logged = payload[:params] }
    ActiveSupport::Notifications.subscribed(subscriber, "start_processing.action_controller") do
      post "/mcp//", params: envelope("tools/call", name: "create_workflow_draft", arguments: { document: }),
                     headers: headers(@drafter)
      assert_response :success
    end
    assert_not_includes logged.to_s, title
    assert_includes logged.to_s, "[FILTERED]"
  end

  private

  def rpc(token, method, **params)
    post mcp_path, params: envelope(method, **params), headers: headers(token)
    assert_response :success
    body = parse(response)
    assert_nil body["error"], "JSON-RPC error: #{body['error'].inspect}"
    body["result"]
  end

  def envelope(method, **params)
    { jsonrpc: "2.0", id: SecureRandom.hex(4), method:, params: }.to_json
  end

  # The transport answers JSON, or one SSE frame on the modern lifecycle; read either.
  def parse(response)
    text = response.body
    text = text.lines.grep(/\Adata: /).last.delete_prefix("data: ") if response.media_type == "text/event-stream"
    JSON.parse(text)
  end

  def base_headers
    { "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream",
      "MCP-Protocol-Version" => "2025-06-18" }
  end

  def headers(token) = base_headers.merge("Authorization" => "Bearer #{token.plaintext}")

  def valid_document
    { schema_version: "1", workflows: [{ title: "MCP #{SecureRandom.hex(2)}",
                                         steps: [{ id: "done", type: "resolve", title: "Done",
                                                   resolution_type: "success" }] }] }
  end

  def dangling_document
    { schema_version: "1", workflows: [{
      title: "Dangling #{SecureRandom.hex(2)}",
      steps: [
        { id: "act", type: "action", title: "Do it", instructions: "Do the thing.",
          transitions: [{ target_id: "nowhere" }] },
        { id: "done", type: "resolve", title: "Done", resolution_type: "success" }
      ]
    }] }
  end
end
