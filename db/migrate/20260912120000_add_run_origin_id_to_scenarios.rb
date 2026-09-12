# Which call a scenario belongs to, written down (ISSUE-003).
#
# Analytics counts calls, and a call can span several scenario rows: a returning
# sub-flow is a child row, and a handoff moves the run to a new row with no
# parent at all. `Scenario#run_origin` answers "which call" by walking both
# links, which SQL cannot do per row. So the answer is stored when a frame is
# created, from the link it is created with, and NULL on an origin: a frame's
# call is `COALESCE(run_origin_id, id)`.
#
# ON DELETE SET NULL for the same reason as its two siblings:
# CleanupScenariosJob deletes with delete_all, which bypasses callbacks. An
# origin is reaped before the frame it handed to (it finished earlier), and by
# then the call started outside every range analytics reads from raw rows.
class AddRunOriginIdToScenarios < ActiveRecord::Migration[8.1]
  class Scenario < ActiveRecord::Base
    self.table_name = "scenarios"
  end

  def up
    add_column :scenarios, :run_origin_id, :integer
    add_index :scenarios, :run_origin_id
    add_foreign_key :scenarios, :scenarios, column: :run_origin_id, on_delete: :nullify

    backfill
  end

  def down
    remove_foreign_key :scenarios, column: :run_origin_id
    remove_index :scenarios, :run_origin_id
    remove_column :scenarios, :run_origin_id
  end

  private

  # The same walk as Scenario#run_origin, over every row at once in memory. A
  # frame carries a parent or a handed_off_from, never both, so following
  # whichever it has is the alternation run_origin makes. The guard mirrors
  # run_origin's: a link to a row that is gone, or a cycle, ends the walk.
  def backfill
    links = Scenario.pluck(:id, :parent_scenario_id, :handed_off_from_id)
                    .to_h { |id, parent, handed_off_from| [id, parent || handed_off_from] }

    origins = links.keys.group_by do |id|
      frame = id
      seen = Set.new
      loop do
        up = links[frame]
        break frame unless up && links.key?(up) && seen.add?(frame)

        frame = up
      end
    end

    backfilled = 0
    origins.each do |origin, frame_ids|
      others = frame_ids - [origin]
      next if others.empty?

      backfilled += Scenario.where(id: others).update_all(run_origin_id: origin)
    end
    say "Recorded the call for #{backfilled} scenario(s) that are not the start of one"
  end
end
