# The step panel's connection editor saved by deleting every transition a step
# had and rebuilding them from what the browser held. Anything written on the
# server while a panel was open - an edge a health fix added, one another editor
# made - was wiped by that panel's next save. A key the browser can know before
# the row exists lets the save say which rows it means, and touch no others.
class AddUuidToTransitions < ActiveRecord::Migration[8.1]
  class MigrationTransition < ActiveRecord::Base
    self.table_name = "transitions"
  end

  def up
    add_column :transitions, :uuid, :string
    MigrationTransition.reset_column_information

    MigrationTransition.where(uuid: nil).in_batches(of: 500) do |batch|
      batch.pluck(:id).each do |id|
        MigrationTransition.where(id: id).update_all(uuid: SecureRandom.uuid)
      end
    end

    change_column_null :transitions, :uuid, false
    add_index :transitions, :uuid, unique: true
  end

  def down
    remove_index :transitions, :uuid
    remove_column :transitions, :uuid
  end
end
