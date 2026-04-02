class AddSharedAccessToScenarios < ActiveRecord::Migration[8.1]
  def change
    add_column :scenarios, :shared_access, :boolean, default: false, null: false
  end
end
