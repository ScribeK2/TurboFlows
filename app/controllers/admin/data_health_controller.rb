module Admin
  class DataHealthController < BaseController
    def index
      @table_sizes = fetch_table_sizes
      @record_counts = fetch_record_counts
      @retention_config = {
        simulation_days: Scenario.simulation_retention_days,
        live_days: Scenario.live_retention_days
      }
      @draft_stats = {
        total: Workflow.draft.count,
        expired: Workflow.expired_drafts.count,
        orphaned: Workflow.orphaned_drafts.count
      }
    end

    def cleanup_drafts
      expired = Workflow.cleanup_expired_drafts
      orphaned = Workflow.cleanup_orphaned_drafts
      redirect_to admin_data_health_path,
                  notice: "Cleaned up #{expired} expired and #{orphaned} orphaned draft(s)."
    end

    private

    def fetch_table_sizes
      tables = %w[scenarios step_responses workflow_versions active_storage_blobs]
      tables.index_with do |table|
        result = ActiveRecord::Base.connection.execute(
          "SELECT pg_size_pretty(pg_total_relation_size(#{ActiveRecord::Base.connection.quote(table)}))"
        )
        result.first["pg_size_pretty"]
      rescue ActiveRecord::StatementInvalid
        "N/A"
      end
    end

    def fetch_record_counts
      {
        scenarios: Scenario.count,
        step_responses: StepResponse.count,
        workflow_versions: WorkflowVersion.count,
        active_storage_blobs: ActiveStorage::Blob.count
      }
    end
  end
end
