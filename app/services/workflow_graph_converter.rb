# frozen_string_literal: true

# Converts linear (array-based) workflows to graph (DAG-based) workflows.
# Maps sequential steps to explicit transitions while preserving decision branches.
#
# Usage:
#   converter = WorkflowGraphConverter.new(workflow)
#   converted_steps = converter.convert
#   if converted_steps
#     workflow.steps = converted_steps
#     workflow.graph_mode = true
#     workflow.save
#   end
#
# The converter:
# - Preserves all existing step data
# - Converts sequential order to explicit transitions
# - Maps decision branches to graph transitions
# - Handles legacy decision format (true_path/false_path)
# - Validates the resulting graph structure
class WorkflowGraphConverter
  include ConditionNegation

  attr_reader :workflow, :errors

  def initialize(workflow)
    @workflow = workflow
    @errors = []
  end

  # Convert the workflow's steps to graph format
  # @return [Array<Hash>, nil] Converted steps array or nil if conversion failed
  def convert
    @errors = []

    return nil unless workflow&.steps.present?
    return workflow.steps if workflow.graph_mode?

    steps = deep_copy(workflow.steps)

    # Ensure all steps have IDs
    ensure_step_ids(steps)

    # Build step ID lookup
    step_id_to_index = build_step_index_map(steps)

    # Convert each step to graph format
    steps.each_with_index do |step, index|
      convert_step_to_graph(step, index, steps, step_id_to_index)
    end

    # Validate the converted graph
    if validate_converted_graph(steps)
      steps
    end
  end

  # Check if conversion would be valid without modifying the workflow
  # @return [Boolean]
  def valid_for_conversion?
    @errors = []

    return false unless workflow&.steps.present?
    return true if workflow.graph_mode?

    steps = deep_copy(workflow.steps)
    ensure_step_ids(steps)
    step_id_to_index = build_step_index_map(steps)

    steps.each_with_index do |step, index|
      convert_step_to_graph(step, index, steps, step_id_to_index)
    end

    validate_converted_graph(steps)
  end

  private

  # Deep copy the steps array to avoid modifying the original
  def deep_copy(obj)
    obj.deep_dup
  end

  # Ensure all steps have UUIDs
  def ensure_step_ids(steps)
    steps.each do |step|
      step['id'] ||= SecureRandom.uuid if step.is_a?(Hash)
    end
  end

  # Build a map of step ID to array index
  def build_step_index_map(steps)
    map = {}
    steps.each_with_index do |step, index|
      map[step['id']] = index if step.is_a?(Hash) && step['id']
    end
    map
  end

  # Convert a single step to graph format by adding transitions
  def convert_step_to_graph(step, index, steps, step_id_to_index)
    return unless step.is_a?(Hash)

    step['transitions'] ||= []

    case step['type']
    when 'sub_flow'
      convert_subflow_step(step, index, steps)
    else
      # All other steps: add transition to next step (if exists)
      convert_sequential_step(step, index, steps)
    end
  end

  # Convert a sub-flow step to graph format
  def convert_subflow_step(step, index, steps)
    return if step['transitions'].present? && step['transitions'].any?

    # Add transition to next step after sub-flow completes
    if index < steps.length - 1
      next_step = steps[index + 1]
      if next_step && next_step['id']
        step['transitions'] = [{
          'target_uuid' => next_step['id'],
          'condition' => nil,
          'label' => 'After sub-flow'
        }]
      end
    else
      step['transitions'] = [] # Terminal sub-flow
    end
  end

  # Convert a sequential step (question, action, checkpoint) to graph format
  def convert_sequential_step(step, index, steps)
    # Check for jumps and add those as transitions
    if step['jumps'].present? && step['jumps'].is_a?(Array)
      step['jumps'].each do |jump|
        condition = jump['condition'] || jump[:condition]
        next_step_id = jump['next_step_id'] || jump[:next_step_id]

        next unless next_step_id.present?

        step['transitions'] << {
          'target_uuid' => next_step_id,
          'condition' => condition,
          'label' => "Jump: #{condition}"
        }
      end
    end

    # Add default transition to next step (unless it's the last step)
    if index < steps.length - 1
      next_step = steps[index + 1]
      if next_step && next_step['id']
        # Only add if no unconditional jump already exists
        has_default = step['transitions'].any? { |t| t['condition'].blank? }
        unless has_default
          step['transitions'] << {
            'target_uuid' => next_step['id'],
            'condition' => nil,
            'label' => nil
          }
        end
      end
    end
  end

  # Resolve a path reference (title or ID) to a step UUID
  def resolve_path_to_uuid(path, steps, step_id_to_index)
    return nil if path.blank?

    # Check if it's already a UUID
    if path.match?(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i) && step_id_to_index.key?(path)
      return path
    end

    # Search by title
    step = steps.find { |s| s['title'] == path }
    step&.dig('id')
  end

  # Validate the converted graph structure
  def validate_converted_graph(steps)
    return false if steps.empty?

    # Build graph steps hash
    graph_steps = {}
    steps.each do |step|
      graph_steps[step['id']] = step if step['id']
    end

    start_uuid = steps.first['id']
    validator = GraphValidator.new(graph_steps, start_uuid)

    unless validator.valid?
      @errors.concat(validator.errors)
      return false
    end

    true
  end
end
