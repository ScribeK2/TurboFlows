class FixStepAndTransitionUniqueness < ActiveRecord::Migration[8.1]
  def change
    # UUID uniqueness should be scoped to workflow (copied workflows share step UUIDs)
    remove_index :steps, :uuid
    add_index :steps, %i[workflow_id uuid], unique: true

    # Allow multiple transitions from same step to same target with different conditions
    remove_index :transitions, %i[step_id target_step_id]
    add_index :transitions, %i[step_id target_step_id condition], unique: true
  end
end
