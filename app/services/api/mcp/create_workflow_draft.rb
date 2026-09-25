module Api
  module Mcp
    class CreateWorkflowDraft < MCP::Tool
      tool_name "create_workflow_draft"
      description "Save a strict-dialect workflow document as a DRAFT in TurboFlows (never published). On success " \
                  "returns each draft's id, title and url; give the url to the person so they can review and " \
                  "publish it. On failure returns the errors to fix and nothing is saved."
      input_schema(properties: { document: DraftDocument::SCHEMA }, required: ["document"],
                   additionalProperties: false)
      annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: false, open_world_hint: false)

      def self.call(document:, server_context:)
        return DraftDocument.refused_scope unless server_context[:api_token].allows?(:draft)

        result = DraftDocument.submission(document, server_context).create
        return ToolResult.refused(result.errors, result.warnings) unless result.created?

        catalog = server_context[:catalog]
        ToolResult.ok(workflows: result.workflows.map { { id: it.id, title: it.title, url: catalog.url_for(it) } },
                      warnings: result.warnings)
      end
    end
  end
end
