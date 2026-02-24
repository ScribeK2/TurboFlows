class AddStatusToSimulations < ActiveRecord::Migration[8.0]
  def change
    add_column :simulations, :status, :string, default: 'active', null: false
    add_column :simulations, :stopped_at_step_index, :integer, null: true
    
    # Update existing simulations: default status is already 'active',
    # no data migration needed for fresh databases
    
    # Add index for better query performance
    add_index :simulations, :status
  end
end
