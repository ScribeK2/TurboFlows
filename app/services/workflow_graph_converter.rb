# Converts linear (array-based) workflows to graph (DAG-based) workflows.
# Maps sequential steps to explicit transitions while preserving decision branches.
#
# Usage:
#   converter = WorkflowGraphConverter.new(workflow)
#   if converter.convert
#     workflow.update!(graph_mode: true)
#   end
#
# The converter:
# - Creates Transition records from sequential step order
# - Converts jump-based branches to graph transitions
# - Handles sub-flow step continuation transitions
# - Validates the resulting graph structure
class WorkflowGraphConverter
  include ConditionNegation

  attr_reader :workflow, :errors

  def initialize(workflow)
    @workflow = workflow
    @errors = []
  end

  # Convert the workflow's steps to graph format
  # Creates Transition records and sets start_step_id
  # @return [Boolean] true if conversion succeeded
  def convert
    @errors = []

    steps = workflow.steps.order(:position).to_a
    return false if steps.empty?
    return true if workflow.start_step_id.present? && workflow.steps.joins(:transitions).exists?

    Workflow.transaction do
      # Remove existing transitions
      Transition.where(step_id: steps.map(&:id)).delete_all

      # Convert each step to graph format
      steps.each_with_index do |step, index|
        convert_step_to_graph(step, index, steps)
      end

      # Set start step
      workflow.update_columns(start_step_id: steps.first.id) unless workflow.start_step_id.present?

      # Validate the converted graph
      unless validate_converted_graph(steps)
        raise ActiveRecord::Rollback
      end
    end

    @errors.empty?
  end

  # Check if conversion would be valid without modifying the workflow
  # @return [Boolean]
  def valid_for_conversion?
    @errors = []

    steps = workflow.steps.order(:position).to_a
    return false if steps.empty?
    return true if workflow.start_step_id.present? && workflow.steps.joins(:transitions).exists?

    # Simulate conversion without saving
    validate_simulated_conversion(steps)
  end

  private

  # Convert a single step to graph format by creating Transition records
  def convert_step_to_graph(step, index, steps)
    case step
    when Steps::SubFlow
      convert_subflow_step(step, index, steps)
    else
      convert_sequential_step(step, index, steps)
    end
  end

  # Convert a sub-flow step: add transition to next step after sub-flow completes
  def convert_subflow_step(step, index, steps)
    return if step.transitions.any?

    if index < steps.length - 1
      next_step = steps[index + 1]
      Transition.create!(
        step: step,
        target_step: next_step,
        label: "After sub-flow",
        position: 0
      )
    end
  end

  # Convert a sequential step: add jump transitions + default next-step transition
  def convert_sequential_step(step, index, steps)
    position = 0

    # Convert jumps to transitions
    if step.jumps.present? && step.jumps.is_a?(Array)
      step.jumps.each do |jump|
        condition = jump["condition"] || jump[:condition]
        next_step_id = jump["next_step_id"] || jump[:next_step_id]
        next unless next_step_id.present?

        target = steps.find { |s| s.uuid == next_step_id }
        next unless target

        Transition.create!(
          step: step,
          target_step: target,
          condition: condition,
          label: condition.present? ? "Jump: #{condition}" : nil,
          position: position
        )
        position += 1
      end
    end

    # Add default transition to next step (unless it's the last step)
    if index < steps.length - 1
      next_step = steps[index + 1]
      # Only add if no unconditional transition already exists
      has_default = step.transitions.reload.any? { |t| t.condition.blank? }
      unless has_default
        Transition.create!(
          step: step,
          target_step: next_step,
          position: position
        )
      end
    end
  end

  # Validate the converted graph structure
  def validate_converted_graph(steps)
    return false if steps.empty?

    graph_steps = {}
    steps.each do |step|
      step_hash = {
        "id" => step.uuid,
        "type" => step.type.demodulize.underscore,
        "title" => step.title,
        "transitions" => step.transitions.reload.map { |t| { "target_uuid" => t.target_step.uuid, "condition" => t.condition } }
      }
      graph_steps[step.uuid] = step_hash
    end

    start_uuid = steps.first.uuid
    validator = GraphValidator.new(graph_steps, start_uuid)

    unless validator.valid?
      @errors.concat(validator.errors)
      return false
    end

    true
  end

  # Simulate conversion to check validity without persisting
  def validate_simulated_conversion(steps)
    simulated_transitions = {}

    steps.each_with_index do |step, index|
      simulated_transitions[step.uuid] = []

      if index < steps.length - 1
        simulated_transitions[step.uuid] << { "target_uuid" => steps[index + 1].uuid }
      end
    end

    graph_steps = {}
    steps.each do |step|
      graph_steps[step.uuid] = {
        "id" => step.uuid,
        "type" => step.type.demodulize.underscore,
        "title" => step.title,
        "transitions" => simulated_transitions[step.uuid] || []
      }
    end

    validator = GraphValidator.new(graph_steps, steps.first.uuid)
    unless validator.valid?
      @errors.concat(validator.errors)
      return false
    end

    true
  end
end
