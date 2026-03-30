class CreateTagsAndTaggings < ActiveRecord::Migration[8.0]
  def change
    create_table :tags do |t|
      t.string :name, null: false
      t.timestamps
    end
    add_index :tags, "LOWER(name)", unique: true, name: "index_tags_on_lower_name"

    create_table :taggings do |t|
      t.references :tag, null: false, foreign_key: true
      t.references :workflow, null: false, foreign_key: true
      t.timestamps
    end
    add_index :taggings, [:tag_id, :workflow_id], unique: true, name: "index_taggings_uniqueness"
  end
end
