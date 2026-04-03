class CreateUserWorkflowPins < ActiveRecord::Migration[8.1]
  def change
    create_table :user_workflow_pins do |t|
      t.references :user, null: false, foreign_key: true
      t.references :workflow, null: false, foreign_key: true

      t.timestamps
    end
    add_index :user_workflow_pins, [:user_id, :workflow_id], unique: true
  end
end
