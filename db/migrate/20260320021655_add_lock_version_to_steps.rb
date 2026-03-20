class AddLockVersionToSteps < ActiveRecord::Migration[8.1]
  def change
    add_column :steps, :lock_version, :integer, default: 0, null: false
  end
end
