# Validates DAG (Directed Acyclic Graph) structure for graph-mode workflows.
# Ensures the workflow graph is valid before execution.
#
# Validations performed:
# - Acyclic: No cycles in the graph (would cause infinite loops)
# - Integrity: All transition target_uuids reference existing steps
# - Reachability: All nodes can be reached from the start node
# - Terminals: At least one terminal node exists (node with no outgoing transitions)
#
# Usage:
#   validator = GraphValidator.new(graph_steps_hash, start_node_uuid)
#   if validator.valid?
#     # Graph is valid
#   else
#     validator.errors # => ["Cycle detected: A -> B -> A", ...]
#   end
class GraphValidator
  attr_reader :errors

  # Initialize with a hash of steps keyed by UUID and the start node UUID
  # @param steps_hash [Hash] Steps hash { "uuid" => step_hash, ... }
  # @param start_uuid [String] UUID of the start node
  def initialize(steps_hash, start_uuid)
    @steps = steps_hash || {}
    @start_uuid = start_uuid
    @errors = []
  end

  # Run all validations and return true if graph is valid
  def valid?
    @errors = []

    validate_has_steps
    return false if @errors.any?

    validate_start_node_exists
    validate_acyclic
    validate_integrity
    validate_reachability
    validate_terminals

    @errors.empty?
  end

  # Check if graph is acyclic (no cycles)
  # Uses DFS with coloring: white (unvisited), gray (in progress), black (finished)
  def validate_acyclic
    return if @steps.empty?

    # Track node states: :white (unvisited), :gray (in current path), :black (fully processed)
    colors = Hash.new(:white)
    path = []

    @steps.each_key do |uuid|
      next unless colors[uuid] == :white

      cycle = detect_cycle_dfs(uuid, colors, path)
      next unless cycle

      cycle_path = cycle.map { |id| step_title(id) }.join(' -> ')
      @errors << "Cycle detected: #{cycle_path}"
      return # Stop at first cycle found
    end
  end

  # Validate all transition target_uuids reference existing steps
  def validate_integrity
    @steps.each do |uuid, step|
      transitions = step['transitions'] || []
      transitions.each_with_index do |transition, index|
        target_uuid = transition['target_uuid']
        next if target_uuid.blank?

        unless @steps.key?(target_uuid)
          step_name = step['title'] || uuid
          @errors << "Step '#{step_name}', Transition #{index + 1}: References non-existent step ID: #{target_uuid}"
        end
      end
    end
  end

  # Validate all nodes are reachable from the start node
  def validate_reachability
    return if @start_uuid.blank?
    return unless @steps.key?(@start_uuid)

    reachable = find_reachable_nodes(@start_uuid)
    unreachable = @steps.keys - reachable

    unreachable.each do |uuid|
      step = @steps[uuid]
      step_name = step['title'] || uuid
      @errors << "Step '#{step_name}' is not reachable from the start node"
    end
  end

  # Validate at least one terminal node exists and all terminals are Resolve steps
  def validate_terminals
    return if @steps.empty?

    terminal_uuids = @steps.select do |_uuid, step|
      transitions = step['transitions'] || []
      transitions.empty?
    end.keys

    if terminal_uuids.empty?
      @errors << "No terminal nodes found. At least one Resolve step is required."
      return
    end

    terminal_uuids.each do |uuid|
      node = @steps[uuid]
      unless node && node["type"] == "resolve"
        @errors << "Terminal node '#{node&.dig("title") || uuid}' is not a Resolve step. All terminal nodes must be Resolve steps."
      end
    end
  end

  private

  def validate_has_steps
    if @steps.empty?
      @errors << "Workflow has no steps"
    end
  end

  def validate_start_node_exists
    return if @start_uuid.blank?

    unless @steps.key?(@start_uuid)
      @errors << "Start node '#{@start_uuid}' does not exist in the workflow"
    end
  end

  # DFS cycle detection with path tracking
  # Returns the cycle path if found, nil otherwise
  def detect_cycle_dfs(uuid, colors, path)
    colors[uuid] = :gray
    path.push(uuid)

    step = @steps[uuid]
    transitions = step&.dig('transitions') || []

    transitions.each do |transition|
      target_uuid = transition['target_uuid']
      next if target_uuid.blank?

      case colors[target_uuid]
      when :gray
        # Found a back edge - cycle detected
        # Return the cycle portion of the path
        cycle_start = path.index(target_uuid)
        return path[cycle_start..] + [target_uuid]
      when :white
        cycle = detect_cycle_dfs(target_uuid, colors, path)
        return cycle if cycle
      end
    end

    path.pop
    colors[uuid] = :black
    nil
  end

  # BFS to find all reachable nodes from start
  def find_reachable_nodes(start_uuid)
    visited = Set.new
    queue = [start_uuid]

    while queue.any?
      current = queue.shift
      next if visited.include?(current)

      visited.add(current)

      step = @steps[current]
      next unless step

      transitions = step['transitions'] || []
      transitions.each do |transition|
        target_uuid = transition['target_uuid']
        queue.push(target_uuid) if target_uuid.present? && !visited.include?(target_uuid)
      end
    end

    visited.to_a
  end

  # Get step title for error messages
  def step_title(uuid)
    step = @steps[uuid]
    step&.dig('title') || uuid
  end
end
