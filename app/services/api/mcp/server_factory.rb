module Api
  module Mcp
    # One MCP::Server per request (the SDK's controller pattern): its tools are
    # the ones this token's effective scopes allow, so tools/list never offers
    # what a call would refuse (spec 2026-09-25-api-and-mcp-design §3). The tools
    # call only Api::WorkflowCatalog and Api::DraftSubmission, the REST API's
    # seams, so the two faces cannot disagree.
    class ServerFactory
      # search_workflows and get_workflow read workflow data, so they stay
      # read-only. get_authoring_guide is static documentation (the strict
      # dialect's schema and prompt, not anyone's workflow), so it is offered
      # to a draft-only token too -- otherwise a draft-only token is told by
      # INSTRUCTIONS and every draft tool's description to call a tool it
      # cannot see.
      READ_ONLY_TOOLS = [SearchWorkflows, GetWorkflow].freeze
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
        tools = api_token.allows?(:read) ? READ_ONLY_TOOLS.dup : []
        tools << GetAuthoringGuide if api_token.allows?(:read) || api_token.allows?(:draft)
        tools + (api_token.allows?(:draft) ? DRAFT_TOOLS : [])
      end

      # The SDK hides an exception's message from the client (CWE-209) and
      # answers "Internal error"; this sends the real one to Rails' error
      # reporter (Sentry in production). context[:request] is what
      # MCP::Server#handle_request was called with as `request` -- a parsed
      # Hash when the SDK's #handle is called directly (server_wire_test), but
      # the raw JSON-RPC **String** over the real HTTP path: the transport
      # calls #handle_json(body_string), and that string, not a parsed Hash,
      # is what every rescue's { request: request } closes over. From Task 3
      # on a tools/call request can carry a whole draft document as an
      # argument -- so only the JSON-RPC method and, for a tool call, the tool
      # name are extracted. Arguments are never forwarded. JSON-RPC allows
      # positional (Array) params, so `params` is checked before `dig`ging
      # into it for a tool name. The whole body is guarded so this reporter
      # can never itself raise: the SDK's own rescue re-raises after calling
      # it, so a raise here replaces the real JSON-RPC error (e.g. the -32602
      # "Tool not found" a scope-filtered tool call should get) with a bare
      # -32603 Internal error, and reports nothing.
      def self.report_exception(exception, context)
        request = parsed_request(context[:request])
        params = request[:params]
        tool = params[:name] if params.is_a?(Hash)
        Rails.error.report(exception, handled: true, context: { mcp: { method: request[:method], tool: } })
      rescue StandardError
        Rails.error.report(exception, handled: true)
      end

      def self.parsed_request(request)
        return request if request.is_a?(Hash)
        return {} unless request.is_a?(String)

        parsed = begin
          JSON.parse(request, symbolize_names: true)
        rescue JSON::ParserError
          {}
        end
        parsed.is_a?(Hash) ? parsed : {}
      end
    end
  end
end
