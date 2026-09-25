module Api
  module Mcp
    # Minimal stub. Task 3 replaces this with the real draft-creation tool.
    class CreateWorkflowDraft < MCP::Tool
      tool_name "create_workflow_draft"
      description "Not built yet."
      input_schema(properties: {}, additionalProperties: false)

      def self.call(server_context:, **)
        ToolResult.refusal("not_implemented", "Not built yet.")
      end
    end
  end
end
