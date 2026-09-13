# A group's standard kit of workflows (spec 2026-09-13-group-featured-workflows),
# shown to its members on the CSR home as "From your team" and curated by
# administrators and the group's managers on the team page. Deleting a group or
# a workflow takes its rows with it; deleting the person who added one keeps it.
class CreateGroupFeaturedWorkflows < ActiveRecord::Migration[8.1]
  def change
    create_table :group_featured_workflows do |t|
      # No index of its own: the unique [group_id, workflow_id] index below leads with it.
      t.references :group, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.references :workflow, null: false, foreign_key: { on_delete: :cascade }
      t.references :added_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :group_featured_workflows, %i[group_id workflow_id], unique: true
    add_index :group_featured_workflows, %i[group_id position]
  end
end
