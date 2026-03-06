class AddAnalyticsColumnsToScenarios < ActiveRecord::Migration[8.1]
  def change
    add_column :scenarios, :purpose, :string, default: "simulation", null: false
    add_column :scenarios, :started_at, :datetime
    add_column :scenarios, :completed_at, :datetime
    add_column :scenarios, :duration_seconds, :integer
    add_column :scenarios, :outcome, :string
    add_column :scenarios, :workflow_version_id, :integer

    add_index :scenarios, [:purpose, :started_at]
    add_index :scenarios, [:workflow_id, :purpose, :outcome]
    add_index :scenarios, [:user_id, :purpose]
    add_index :scenarios, :outcome
    add_index :scenarios, :workflow_version_id

    add_foreign_key :scenarios, :workflow_versions, column: :workflow_version_id, on_delete: :nullify
  end
end
