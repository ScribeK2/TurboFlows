# Existing Resolve and Escalate steps saved before the models had defaults can
# hold NULL or "" where the panel always showed Success and Low. The models now
# read a blank as "success" / "medium"; this makes the rows say it too, so
# exports, imports and analytics never see the blank. Both are the values the
# runner treats as the quiet case, so nothing an agent sees changes.
class BackfillStepDefaults < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE steps SET resolution_type = 'success'
      WHERE type = 'Steps::Resolve' AND (resolution_type IS NULL OR resolution_type = '')
    SQL
    execute <<~SQL.squish
      UPDATE steps SET priority = 'medium'
      WHERE type = 'Steps::Escalate' AND (priority IS NULL OR priority = '')
    SQL
  end

  def down
    # The blanks carried no information; there is nothing to restore.
  end
end
