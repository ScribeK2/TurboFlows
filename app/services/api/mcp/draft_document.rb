module Api
  module Mcp
    # Shared by the two draft tools. A model may send the document as an object
    # or as a JSON string; Api::DraftSubmission takes a string, so an object is
    # serialized. A string goes through untouched, so a malformed one reaches
    # the validator and comes back as a malformed_json finding.
    module DraftDocument
      SCHEMA = {
        type: %w[object string],
        description: "A strict-dialect document: { \"schema_version\": \"1\", \"workflows\": [ ... ] }. " \
                     "Call get_authoring_guide for the full schema."
      }.freeze

      module_function

      def submission(document, server_context)
        content = document.is_a?(String) ? document : JSON.generate(document)
        Api::DraftSubmission.new(user: server_context[:user], api_token: server_context[:api_token], content:)
      end

      def refused_scope
        ToolResult.refusal("insufficient_scope",
                           "This token doesn't have the draft scope, or your role no longer allows it.")
      end
    end
  end
end
