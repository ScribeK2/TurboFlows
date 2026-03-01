class CreateWorkflowVersions < ActiveRecord::Migration[8.0]
  def change
    create_table :workflow_versions do |t|
      t.references :workflow, null: false, foreign_key: true
      t.integer :version_number, null: false
      t.json :steps_snapshot, null: false
      t.json :metadata_snapshot, null: false, default: {}
      t.references :published_by, null: false, foreign_key: { to_table: :users }
      t.datetime :published_at, null: false
      t.text :changelog

      t.timestamps
    end

    add_index :workflow_versions, [:workflow_id, :version_number], unique: true
    add_index :workflow_versions, :published_at
  end
end
