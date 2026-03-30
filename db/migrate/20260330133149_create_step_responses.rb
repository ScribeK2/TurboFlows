class CreateStepResponses < ActiveRecord::Migration[8.1]
  def change
    create_table :step_responses do |t|
      t.references :scenario, null: false, foreign_key: true
      t.references :step, null: false, foreign_key: true
      t.json :responses, default: {}
      t.datetime :submitted_at, null: false

      t.timestamps
    end

    add_index :step_responses, [:scenario_id, :step_id]
  end
end
