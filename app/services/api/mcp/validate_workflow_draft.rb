module Api
  module Mcp
    # Minimal stub. Task 3 replaces this with the real validation tool.
    class ValidateWorkflowDraft < MCP::Tool
      tool_name "validate_workflow_draft"
      description "Not built yet."

      def self.call(server_context:, **)
        ToolResult.refusal("not_implemented", "Not built yet.")
      end
    end
  end
end
