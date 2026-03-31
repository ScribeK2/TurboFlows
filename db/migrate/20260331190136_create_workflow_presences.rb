class CreateWorkflowPresences < ActiveRecord::Migration[8.1]
  def change
    create_table :workflow_presences do |t|
      t.references :workflow, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :user_name, null: false
      t.string :user_email, null: false
      t.datetime :last_seen_at, null: false

      t.index [:workflow_id, :user_id], unique: true
      t.index :last_seen_at
    end
  end
end
