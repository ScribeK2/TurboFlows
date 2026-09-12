# Who manages a group (spec 2026-09-12). A manager sees Analytics for the group's
# members and its sub-teams. Kept apart from user_groups on purpose: people join
# and leave groups themselves, and managing a team is neither.
class CreateGroupManagers < ActiveRecord::Migration[8.1]
  def change
    create_table :group_managers do |t|
      # No index of its own: the unique [group_id, user_id] index below leads with it.
      t.references :group, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
    end
    add_index :group_managers, %i[group_id user_id], unique: true
  end
end
