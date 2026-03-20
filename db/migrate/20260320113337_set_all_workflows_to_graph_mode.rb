class SetAllWorkflowsToGraphMode < ActiveRecord::Migration[8.1]
  def up
    Workflow.where(graph_mode: false).update_all(graph_mode: true)
    change_column_default :workflows, :graph_mode, true
  end

  def down
    change_column_default :workflows, :graph_mode, false
  end
end
