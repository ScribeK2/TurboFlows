class AddSharingToWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_column :workflows, :share_token, :string
    add_column :workflows, :embed_enabled, :boolean, default: false, null: false
    add_index :workflows, :share_token, unique: true
  end
end
