module Api
  module Mcp
    class GetWorkflow < MCP::Tool
      tool_name "get_workflow"
      description "Fetch one workflow you can see, as a TurboFlows strict-dialect document: the same format " \
                  "create_workflow_draft accepts, so it can be used as a worked example."
      input_schema(
        properties: { id: { type: %w[integer string], description: "The workflow id from search_workflows." } },
        required: ["id"]
      )
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      NOT_FOUND = "No workflow with that id is visible to this token.".freeze

      def self.call(id:, server_context:)
        workflow_id = Integer(id.to_s, exception: false)
        return ToolResult.refusal("not_found", NOT_FOUND) unless workflow_id

        catalog = server_context[:catalog]
        ToolResult.ok(catalog.document(catalog.find(workflow_id)))
      rescue ActiveRecord::RecordNotFound
        ToolResult.refusal("not_found", NOT_FOUND)
      end
    end
  end
end
