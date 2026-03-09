class CreateTransitions < ActiveRecord::Migration[8.1]
  def change
    create_table :transitions do |t|
      t.references :step, null: false, foreign_key: true
      t.references :target_step, null: false, foreign_key: { to_table: :steps }
      t.string     :condition
      t.string     :label
      t.integer    :position

      t.timestamps
    end

    add_index :transitions, [:step_id, :target_step_id], unique: true
  end
end
