class MigrateRichTextDescriptionsToMarkdown < ActiveRecord::Migration[8.0]
  def up
    # Copy Action Text rich text HTML bodies into the native workflows.description column.
    # Only overwrites if the native column is empty (preserves any existing plain text).
    # The HTML will be converted to markdown by the rake task below.
    execute <<~SQL.squish
      UPDATE workflows
      SET description = (
        SELECT body
        FROM action_text_rich_texts
        WHERE action_text_rich_texts.record_type = 'Workflow'
          AND action_text_rich_texts.record_id   = workflows.id
          AND action_text_rich_texts.name         = 'description'
      )
      WHERE EXISTS (
        SELECT 1
        FROM action_text_rich_texts
        WHERE action_text_rich_texts.record_type = 'Workflow'
          AND action_text_rich_texts.record_id   = workflows.id
          AND action_text_rich_texts.name         = 'description'
      )
      AND (workflows.description IS NULL OR workflows.description = '')
    SQL
  end

  def down
    # No-op: original Action Text records remain in action_text_rich_texts
  end
end
