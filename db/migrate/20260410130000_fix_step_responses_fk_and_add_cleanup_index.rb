class FixStepResponsesFkAndAddCleanupIndex < ActiveRecord::Migration[8.1]
  def up
    # Fix FK: drop RESTRICT (default), add CASCADE so delete_all on scenarios
    # automatically removes associated step_responses at the DB level.
    # cleanup_stale uses delete_all for performance (bypasses ActiveRecord callbacks),
    # so the FK must handle cascading.
    remove_foreign_key :step_responses, :scenarios
    add_foreign_key :step_responses, :scenarios, on_delete: :cascade

    # Backfill completed_at for terminal scenarios that have it NULL.
    # This allows the stale scopes to use completed_at directly instead of
    # COALESCE(completed_at, updated_at), which defeats standard B-tree indexes.
    execute <<~SQL.squish
      UPDATE scenarios
      SET completed_at = updated_at
      WHERE completed_at IS NULL
        AND status IN ('completed', 'stopped', 'timeout', 'error')
    SQL

    # Composite index for the batched cleanup scopes.
    # stale_simulations and stale_live filter on status + purpose + completed_at.
    add_index :scenarios, %i[status purpose completed_at],
              name: "index_scenarios_on_cleanup_scope"
  end

  def down
    remove_index :scenarios, name: "index_scenarios_on_cleanup_scope"
    remove_foreign_key :step_responses, :scenarios
    add_foreign_key :step_responses, :scenarios
  end
end
