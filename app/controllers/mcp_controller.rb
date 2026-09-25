# The MCP endpoint (spec 2026-09-25-api-and-mcp-design §3). Token-only, like
# /api/v1. A fresh server per request, in stateless mode: production runs several
# Puma workers and the SDK keeps session state per process, so nothing may
# depend on a session surviving to the next request.
class McpController < ActionController::API
  include Api::TokenAuthentication

  wrap_parameters false

  def handle
    server = Api::Mcp::ServerFactory.build(user: current_user, api_token: current_api_token,
                                           base_url: request.base_url)
    status, headers, body = transport(server).handle_request(request)

    self.status = status
    response.headers.merge!(headers)
    self.response_body = body
  end

  private

  # stateless + no listen streams => the body is always an Array of Strings,
  # never a streaming Proc, so handing it to Rails as-is is safe.
  def transport(server)
    MCP::Server::Transports::StreamableHTTPTransport.new(
      server,
      stateless: true,
      serve_subscriptions_listen: false,
      enable_json_response: true,
      dns_rebinding_protection: false,
      max_request_bytes: Api::DraftBodyGuard::MCP_MAX_BYTES
    )
  end
end
