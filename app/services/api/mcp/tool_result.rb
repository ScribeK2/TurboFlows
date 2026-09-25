module Api
  module Mcp
    # How every TurboFlows MCP tool answers. The data is sent twice: as
    # structured content, and as its JSON in a text block for clients that read
    # only text. A refusal is a tool result with isError, carrying the same
    # findings shape as the REST API, so the model reads it and retries. It is
    # never a JSON-RPC error (spec 2026-09-25-api-and-mcp-design §3).
    module ToolResult
      module_function

      def ok(data)
        MCP::Tool::Response.new([{ type: "text", text: JSON.generate(data) }], structured_content: data)
      end

      def refused(errors, warnings = [])
        data = { errors:, warnings: }
        MCP::Tool::Response.new([{ type: "text", text: JSON.generate(data) }], structured_content: data, error: true)
      end

      def refusal(code, message) = refused([{ path: nil, code:, message: }])
    end
  end
end
