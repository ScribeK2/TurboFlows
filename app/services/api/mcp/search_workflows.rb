module Api
  module Mcp
    class SearchWorkflows < MCP::Tool
      tool_name "search_workflows"
      description "Search the TurboFlows workflows you can see (published ones in your groups, plus your own " \
                  "drafts). Returns id, title, description, status, tags, groups and a link for each, 25 per page."
      input_schema(
        properties: {
          query: { type: "string", description: "Words to find in a title or description." },
          tag: { type: "string", description: "Only workflows with this tag (case-insensitive)." },
          group: { type: "integer", description: "Only workflows filed in this group id or its subgroups." },
          status: { type: "string", enum: %w[published draft] },
          page: { type: "integer", minimum: 1, description: "Page number; see next_page in the result." }
        }
      )
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(server_context:, query: nil, tag: nil, group: nil, status: nil, page: nil)
        catalog = server_context[:catalog]
        result = catalog.search(q: query, tag:, group:, status:, page:)
        ToolResult.ok(workflows: result.workflows.map { catalog.summary(it) }, next_page: result.next_page)
      rescue Api::WorkflowCatalog::InvalidFilter => e
        ToolResult.refusal("invalid_filter", e.message)
      end
    end
  end
end
