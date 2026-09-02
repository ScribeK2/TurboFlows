# Validates graph structure for graph-mode workflows. Ensures the workflow
# graph is valid before execution.
#
# Validations performed:
# - Escapability: every step reachable from start can still reach a Resolve
#   step. Cycles are legal (a retry loop is the canonical call-centre shape) —
#   what is not legal is a loop with no way out.
# - Integrity: All transition target_uuids reference existing steps
# - Reachability: All nodes can be reached from the start node
# - Terminals: At least one terminal node exists (node with no outgoing transitions)
#
# Reporting: validations append Findings, which carry the code and the UUID of
# the step at fault. #errors is a projection of those findings for callers that
# only want sentences (AR validation, publish, import, conversion). Consumers
# that need to know *which* step failed read #findings and switch on the code —
# never regex the message back into a step, because titles are not unique.
#
# Usage:
#   validator = GraphValidator.new(graph_steps_hash, start_node_uuid)
#   if validator.valid?
#     # Graph is valid
#   else
#     validator.findings # => [#<ValidationFinding code: :no_path_to_resolve, step_uuid: "...">]
#     validator.errors   # => ["Step 'B' has no path to a Resolve step.", ...]
#   end
class GraphValidator
  attr_reader :findings

  # Initialize with a hash of steps keyed by UUID and the start node UUID
  # @param steps_hash [Hash] Steps hash { "uuid" => step_hash, ... }
  # @param start_uuid [String] UUID of the start node
  def initialize(steps_hash, start_uuid)
    @steps = steps_hash || {}
    @start_uuid = start_uuid
    @findings = []
  end

  # Human-readable messages, in findings order. Kept so callers that only
  # surface text (Workflow validation, WorkflowPublisher, WorkflowImporter,
  # WorkflowGraphConverter, TransitionBuilder) need no knowledge of findings.
  def errors
    @findings.map(&:message)
  end

  # Run all validations and return true if graph is valid
  def valid?
    @findings = []

    validate_has_steps
    return false if @findings.any?

    validate_start_node_exists
    validate_escapable
    validate_integrity
    validate_reachability
    validate_terminals

    @findings.empty?
  end

  # Every step must be able to reach a Resolve. This replaces the old acyclic
  # check: a loop is a legitimate shape here ("didn't work — try again" is how
  # call-centre troubleshooting works), but a loop with no exit traps an agent
  # mid-call until Scenario::MAX_ITERATIONS blows the run up.
  #
  # For an acyclic graph this asserts nothing new — every node in a finite DAG
  # reaches some terminal, and validate_terminals already requires terminals to
  # be Resolve steps. It only grows teeth once a cycle is present.
  #
  # Only steps reachable from the start are checked; unreachable ones are
  # validate_reachability's to report, and reporting both would name the same
  # step twice for two different reasons.
  def validate_escapable
    return if @steps.empty?
    return if @start_uuid.blank? || !@steps.key?(@start_uuid)

    escapable = escapable_uuids
    # find_reachable_nodes queues transition targets before checking they're
    # real steps (validate_integrity's job), so a target uuid pointing at a
    # deleted step ends up "reachable" with no step behind it. Intersect with
    # @steps.keys so no finding ever names a step that doesn't exist —
    # validate_reachability guards the same way for the same reason.
    reachable = find_reachable_nodes(@start_uuid) & @steps.keys

    (reachable - escapable.to_a).each do |uuid|
      step = @steps[uuid]
      add_finding(:no_path_to_resolve,
                  "Step '#{step&.dig('title') || uuid}' has no path to a Resolve step.",
                  step_uuid: uuid)
    end
  end

  # Validate all transition target_uuids reference existing steps
  def validate_integrity
    @steps.each do |uuid, step|
      transitions = step['transitions'] || []
      transitions.each_with_index do |transition, index|
        target_uuid = transition['target_uuid']
        next if target_uuid.blank?
        next if @steps.key?(target_uuid)

        step_name = step['title'] || uuid
        add_finding(:transition_target_missing,
                    "Step '#{step_name}', Transition #{index + 1}: References non-existent step ID: #{target_uuid}",
                    step_uuid: uuid,
                    details: { target_uuid: target_uuid, transition_index: index })
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
      add_finding(:unreachable_step, "Step '#{step_name}' is not reachable from the start node",
                  step_uuid: uuid)
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
      add_finding(:no_terminal_nodes, "No terminal nodes found. At least one Resolve step is required.")
      return
    end

    terminal_uuids.each do |uuid|
      node = @steps[uuid]
      next if node && node["type"] == "resolve"

      add_finding(:terminal_not_resolve,
                  "Terminal node '#{node&.dig('title') || uuid}' is not a Resolve step. All terminal nodes must be Resolve steps.",
                  step_uuid: uuid)
    end
  end

  private

  def add_finding(code, message, step_uuid: nil, details: {})
    @findings << ValidationFinding.new(code:, step_uuid:, message:, details:)
  end

  def validate_has_steps
    add_finding(:no_steps, "Workflow has no steps") if @steps.empty?
  end

  def validate_start_node_exists
    return if @start_uuid.blank?
    return if @steps.key?(@start_uuid)

    add_finding(:start_node_missing, "Start node '#{@start_uuid}' does not exist in the workflow",
                details: { start_uuid: @start_uuid })
  end

  # Reverse BFS from the Resolve terminals. Linear, and cycle-safe by
  # construction since a node is enqueued at most once.
  def escapable_uuids
    incoming = Hash.new { |h, k| h[k] = [] }
    @steps.each do |uuid, step|
      transition_target_uuids(step).each { |target| incoming[target] << uuid }
    end

    frontier = @steps.select { |_uuid, step| terminal_resolve?(step) }.keys
    escapable = frontier.to_set

    until frontier.empty?
      frontier = frontier.flat_map { |uuid| incoming[uuid] }.reject { |uuid| escapable.include?(uuid) }
      frontier.each { |uuid| escapable.add(uuid) }
    end

    escapable
  end

  def terminal_resolve?(step)
    step["type"] == "resolve" && transition_target_uuids(step).empty?
  end

  def transition_target_uuids(step)
    Array(step["transitions"]).filter_map { |t| t.is_a?(Hash) ? t["target_uuid"] : nil }
                              .select { |uuid| @steps.key?(uuid) }
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
        queue.push(target_uuid) if target_uuid.present? && visited.exclude?(target_uuid)
      end
    end

    visited.to_a
  end
end
