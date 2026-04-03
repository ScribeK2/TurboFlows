class AddDashboardIndexesToScenarios < ActiveRecord::Migration[8.1]
  def change
    add_index :scenarios, [:user_id, :purpose, :created_at]
    add_index :scenarios, [:user_id, :workflow_id]
    remove_index :scenarios, [:user_id, :purpose]
  end
end
