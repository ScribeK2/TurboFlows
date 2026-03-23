class DropTemplates < ActiveRecord::Migration[8.1]
  def up
    drop_table :templates
  end

  def down
    create_table :templates do |t|
      t.string :name, null: false
      t.text :description
      t.json :workflow_data
      t.string :category
      t.boolean :is_public, default: true
      t.boolean :graph_mode, default: true
      t.string :start_node_uuid
      t.timestamps
    end
    add_index :templates, :category
    add_index :templates, :is_public
  end
end
