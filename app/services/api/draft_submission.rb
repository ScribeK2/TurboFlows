module Api
  # Checks and writes one strict-dialect submission from a token. The REST
  # controllers and the MCP tools both call only this, so the order below is
  # the only order there is (spec 2026-09-25-api-and-mcp-design §2):
  #
  #   cap (already full?) → StrictImportValidator → cap (does this fit?) →
  #   WorkflowImporter, which stamps api_token_id inside its transaction.
  #
  # The cap is checked twice. The first check spares an agent from fixing ten
  # findings only to hit a limit it could have been told about at once. The
  # second needs the validator's count of workflows in the bundle, and refuses
  # the whole bundle before anything is written.
  class DraftSubmission
    DRAFT_LIMIT = 50

    Result = Data.define(:workflows, :errors, :warnings) do
      def created? = errors.empty?
    end

    def initialize(user:, api_token:, content:)
      @user = user
      @api_token = api_token
      @content = content.to_s
    end

    def validate
      return { valid: false, errors: [oversized_finding], warnings: [] } if oversized?

      report = validator_report
      { valid: report.valid?, errors: report.errors, warnings: report.warnings }
    end

    def create
      return refused([oversized_finding]) if oversized?
      return refused([limit_finding(0)]) if outstanding >= DRAFT_LIMIT

      report = validator_report
      return refused(report.errors, report.warnings) unless report.valid?

      incoming = report.workflows_data.size
      return refused([limit_finding(incoming)], report.warnings) if outstanding + incoming > DRAFT_LIMIT

      result = WorkflowImporter.new(@user, format: :json, content: @content, strict_report: report,
                                           api_token: @api_token).call
      return Result.new(workflows: result.workflows, errors: [], warnings: report.warnings) if result.success?

      refused(result.errors.map { { path: nil, code: "refused_at_commit", message: it.to_s, value: nil } },
              report.warnings)
    end

    private

    def validator_report
      @validator_report ||= StrictImportValidator.new(user: @user, content: @content).validate
    end

    # The MCP cap (Api::DraftBodyGuard::MCP_MAX_BYTES) has 1 MB of headroom
    # over WorkflowImporter::MAX_IMPORT_BYTES for the JSON-RPC envelope
    # (method, tool name, arguments key) -- a document between the two sizes
    # passes the middleware but must still be refused here, the one seam both
    # REST and MCP call, so a document too big to import over REST cannot be
    # created over MCP.
    def oversized?
      @content.bytesize > WorkflowImporter::MAX_IMPORT_BYTES
    end

    def oversized_finding
      { path: nil, code: "payload_too_large", value: @content.bytesize,
        message: "The document is over #{WorkflowImporter::MAX_IMPORT_BYTES / 1.megabyte} MB." }
    end

    def outstanding
      Workflow.drafts.created_via_api.where(user: @user).count
    end

    def refused(errors, warnings = []) = Result.new(workflows: [], errors:, warnings:)

    def limit_finding(incoming)
      { path: nil, code: "api_draft_limit", value: outstanding,
        message: "You have #{outstanding} drafts made through the API; the limit is #{DRAFT_LIMIT}" \
                 "#{" and this would add #{incoming}" if incoming.positive?}. Ask a person to review, " \
                 "publish or delete some in TurboFlows, then try again." }
    end
  end
end
