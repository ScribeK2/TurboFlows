module Api
  module Mcp
    class ValidateWorkflowDraft < MCP::Tool
      tool_name "validate_workflow_draft"
      description "Check a strict-dialect workflow document without saving anything. Returns valid, plus every " \
                  "error and warning at once, each with a path, a code and what to change. Fix every error, then " \
                  "call create_workflow_draft."
      input_schema(properties: { document: DraftDocument::SCHEMA }, required: ["document"],
                   additionalProperties: false)
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(document:, server_context:)
        return DraftDocument.refused_scope unless server_context[:api_token].allows?(:draft)

        ToolResult.ok(DraftDocument.submission(document, server_context).validate)
      end
    end
  end
end
