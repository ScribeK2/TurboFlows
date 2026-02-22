class RenameSimulationsToScenarios < ActiveRecord::Migration[8.0]
  def change
    rename_table :simulations, :scenarios
    rename_column :scenarios, :parent_simulation_id, :parent_scenario_id
  end
end
