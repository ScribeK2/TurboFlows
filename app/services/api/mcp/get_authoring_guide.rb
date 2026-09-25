module Api
  module Mcp
    class GetAuthoringGuide < MCP::Tool
      tool_name "get_authoring_guide"
      description "Read this before writing a workflow: the JSON Schema and the authoring guide for TurboFlows' " \
                  "strict import dialect, which validate_workflow_draft and create_workflow_draft accept."
      input_schema(properties: {}, additionalProperties: false)
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(server_context:)
        ToolResult.ok(schema_version: ImportSchemaGenerator::SCHEMA_VERSION,
                      schema: ImportSchemaGenerator.call,
                      guide: ImportPromptGenerator.call)
      end
    end
  end
end
