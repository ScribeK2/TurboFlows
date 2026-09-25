module Api
  module Mcp
    # One MCP::Server per request (the SDK's controller pattern): its tools are
    # the ones this token's effective scopes allow, so tools/list never offers
    # what a call would refuse (spec 2026-09-25-api-and-mcp-design §3). The tools
    # call only Api::WorkflowCatalog and Api::DraftSubmission, the REST API's
    # seams, so the two faces cannot disagree.
    class ServerFactory
      READ_TOOLS = [SearchWorkflows, GetWorkflow, GetAuthoringGuide].freeze
      DRAFT_TOOLS = [ValidateWorkflowDraft, CreateWorkflowDraft].freeze

      INSTRUCTIONS = <<~TEXT.squish.freeze
        TurboFlows holds step-by-step workflows for call and chat centre staff. To find or read one, use
        search_workflows and get_workflow. To write one: call get_authoring_guide first; build a strict-dialect
        document; call validate_workflow_draft and fix every error it reports (each names a path, a code and what
        to change); then call create_workflow_draft and give the person the url it returns. Drafts are never
        published by these tools: a person reviews and publishes them in TurboFlows.
      TEXT

      def self.build(user:, api_token:, base_url:)
        MCP::Server.new(
          name: "turboflows",
          title: "TurboFlows",
          version: "1.0.0",
          instructions: INSTRUCTIONS,
          tools: tools_for(api_token),
          server_context: { user:, api_token:, catalog: Api::WorkflowCatalog.new(user, base_url:) },
          configuration: MCP::Configuration.new(exception_reporter: method(:report_exception))
        )
      end

      def self.tools_for(api_token)
        (api_token.allows?(:read) ? READ_TOOLS : []) + (api_token.allows?(:draft) ? DRAFT_TOOLS : [])
      end

      # The SDK hides an exception's message from the client (CWE-209) and
      # answers "Internal error"; this sends the real one to Rails' error
      # reporter (Sentry in production).
      def self.report_exception(exception, context)
        Rails.error.report(exception, handled: true, context: { mcp: context.to_s.truncate(500) })
      end
    end
  end
end
