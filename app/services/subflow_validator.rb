# frozen_string_literal: true

# Validates sub-flow references to prevent circular dependencies.
# A circular dependency would cause infinite recursion during execution.
#
# Example of circular dependency:
#   Workflow A -> references Workflow B as sub-flow
#   Workflow B -> references Workflow A as sub-flow
#   This would cause infinite recursion: A -> B -> A -> B -> ...
#
# Usage:
#   validator = SubflowValidator.new(workflow_id)
#   if validator.valid?
#     # No circular references
#   else
#     validator.errors # => ["Circular sub-flow reference: Workflow A -> Workflow B -> Workflow A"]
#   end
class SubflowValidator
  attr_reader :errors

  MAX_DEPTH = 10 # Maximum sub-flow nesting depth

  # Initialize with the workflow ID to validate
  # @param workflow_id [Integer] The ID of the workflow to validate
  def initialize(workflow_id)
    @workflow_id = workflow_id
    @errors = []
  end

  # Run validation and return true if no circular references exist
  def valid?
    @errors = []

    root = Workflow.find_by(id: @workflow_id)
    return true unless root

    # Batch-load all reachable workflows upfront
    @workflows_cache = preload_reachable_workflows(root)

    validate_no_circular_subflows(root, [])
    validate_max_depth(root)

    @errors.empty?
  end

  # Class method for quick validation
  def self.valid?(workflow_id)
    new(workflow_id).valid?
  end

  # Class method to get all errors
  def self.errors_for(workflow_id)
    validator = new(workflow_id)
    validator.valid?
    validator.errors
  end

  private

  # Batch-load all workflows reachable via sub-flow references
  # Uses a single bulk query to load all potentially reachable workflows,
  # then verifies connectivity in-memory
  # @param root [Workflow] The starting workflow
  # @return [Hash<Integer, Workflow>] Cache of workflow_id => workflow
  def preload_reachable_workflows(root)
    cache = { root.id => root }
    initial_ids = extract_subflow_target_ids(root)
    return cache if initial_ids.empty?

    # Load all initial targets in one query
    batch = Workflow.where(id: initial_ids).to_a
    batch.each { |w| cache[w.id] = w }

    # Collect any further references from loaded workflows
    loaded_ids = cache.keys.to_set
    new_ids = batch.flat_map { |w| extract_subflow_target_ids(w) }.uniq - loaded_ids.to_a

    # Continue loading in batches until no new IDs are found
    while new_ids.any?
      next_batch = Workflow.where(id: new_ids).to_a
      next_batch.each { |w| cache[w.id] = w }
      loaded_ids.merge(new_ids)

      new_ids = next_batch.flat_map { |w| extract_subflow_target_ids(w) }.uniq - loaded_ids.to_a
    end

    cache
  end

  # Extract target workflow IDs from sub-flow steps
  # @param workflow [Workflow] The workflow to extract from
  # @return [Array<Integer>] Array of target workflow IDs
  def extract_subflow_target_ids(workflow)
    return [] unless workflow.steps.is_a?(Array)

    workflow.steps
      .select { |s| (s["type"] == "sub_flow" || s["type"] == "sub-flow") && s["target_workflow_id"].present? }
      .map { |s| s["target_workflow_id"].to_i }
  end

  # Recursively check for circular sub-flow references
  # Uses DFS with path tracking to detect cycles
  # @param workflow [Workflow] The current workflow being validated
  # @param visited_path [Array<Integer>] Path of workflow IDs visited so far
  def validate_no_circular_subflows(workflow, visited_path)
    return if workflow.nil?

    if visited_path.include?(workflow.id)
      cycle_start = visited_path.index(workflow.id)
      cycle_path = visited_path[cycle_start..] + [workflow.id]
      cycle_names = cycle_path.map { |wid| @workflows_cache[wid]&.title || "Workflow ##{wid}" }
      @errors << "Circular sub-flow reference: #{cycle_names.join(' -> ')}"
      return
    end

    extract_subflow_target_ids(workflow).each do |target_id|
      target = @workflows_cache[target_id]
      unless target
        @errors << "Sub-flow references non-existent workflow (ID: #{target_id})"
        next
      end
      validate_no_circular_subflows(target, visited_path + [workflow.id])
    end
  end

  # Validate that sub-flow nesting doesn't exceed maximum depth
  # @param workflow [Workflow] The workflow to validate
  def validate_max_depth(workflow)
    depth = calculate_max_depth(workflow, Set.new)

    if depth > MAX_DEPTH
      @errors << "Sub-flow nesting exceeds maximum depth of #{MAX_DEPTH} levels"
    end
  end

  # Calculate the maximum nesting depth of sub-flows
  # @param workflow [Workflow] The current workflow
  # @param visited [Set<Integer>] Set of visited workflow IDs (to prevent infinite loops)
  # @return [Integer] The maximum depth
  def calculate_max_depth(workflow, visited)
    return 0 if workflow.nil?
    return 0 if visited.include?(workflow.id)

    visited.add(workflow.id)

    target_ids = extract_subflow_target_ids(workflow)
    return 1 if target_ids.empty?

    max_child_depth = target_ids.map do |tid|
      calculate_max_depth(@workflows_cache[tid], visited.dup)
    end.max || 0

    1 + max_child_depth
  end
end
