# Personal API tokens (spec 2026-09-25-api-and-mcp-design §1). Only a SHA-256
# digest is stored: the raw token is shown once, at creation, and never again.
class CreateApiTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :api_tokens do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.json :scopes, null: false, default: []
      t.string :token_digest, null: false
      t.datetime :last_used_at
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :api_tokens, :token_digest, unique: true
  end
end
