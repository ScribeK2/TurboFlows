# Which token made a draft (spec 2026-09-25-api-and-mcp-design §2, Provenance).
# Nullable, no backfill: nothing existing was made through the API.
class AddApiTokenToWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_reference :workflows, :api_token, null: true, foreign_key: { on_delete: :nullify }
  end
end
