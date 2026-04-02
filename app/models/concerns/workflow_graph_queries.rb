# Handles graph traversal query helpers for workflows.
# Provides accessors for graph steps, start node, and terminal nodes.
module WorkflowGraphQueries
  extend ActiveSupport::Concern

  # All workflows are now graph mode — column kept for backward compatibility
  def graph_mode?
    true
  end

  # Linear mode is no longer supported
  def linear_mode?
    false
  end

  # Get steps as a hash keyed by UUID for graph-based operations
  def graph_steps
    steps.includes(:transitions).index_by(&:uuid)
  end

  # Get the starting node for graph traversal
  def start_node
    start_step || steps.first
  end

  # Get all terminal steps (no outgoing transitions)
  def terminal_nodes
    steps.where.missing(:transitions)
  end
end
