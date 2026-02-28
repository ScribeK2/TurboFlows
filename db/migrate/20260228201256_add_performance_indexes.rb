class AddPerformanceIndexes < ActiveRecord::Migration[8.0]
  def change
    add_index :workflows, :updated_at, if_not_exists: true
    add_column :workflows, :steps_count, :integer, default: 0, null: false

    reversible do |dir|
      dir.up do
        execute <<~SQL
          UPDATE workflows SET steps_count = COALESCE(json_array_length(steps), 0)
        SQL
      end
    end
  end
end
