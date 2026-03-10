# Resolves the next step in a graph-mode workflow based on current step and results.
# Handles transition condition evaluation and sub-flow detection.
#
# Usage:
#   resolver = StepResolver.new(workflow)
#   next_step = resolver.resolve_next(current_step, results)
#
# Returns:
#   - Step instance of the next step
#   - SubflowMarker if a sub-flow step is hit
#   - nil if no valid transition or terminal node
class StepResolver
  # Marker returned when a sub-flow step is encountered
  SubflowMarker = Data.define(:target_workflow_id, :variable_mapping, :step_uuid)

  attr_reader :workflow

  def initialize(workflow)
    @workflow = workflow
  end

  # Resolve the next step from the current step
  # @param step [Step] The current step
  # @param results [Hash] Current scenario results (variable values)
  # @return [Step, SubflowMarker, nil]
  def resolve_next(step, results)
    return nil unless step

    if step.is_a?(Steps::SubFlow)
      return SubflowMarker.new(
        target_workflow_id: step.sub_flow_workflow_id,
        variable_mapping: step.variable_mapping || {},
        step_uuid: step.uuid
      )
    end

    resolve_graph_next(step, results)
  end

  # Resolve the next step after a sub-flow completes
  # @param step [Step] The sub_flow step that just completed
  # @param results [Hash] Current scenario results
  # @return [Step, nil]
  def resolve_next_after_subflow(step, results)
    return nil unless step
    resolve_graph_next(step, results)
  end

  # Find the start step for this workflow
  # @return [Step, nil]
  def start_step
    @workflow.start_step || @workflow.workflow_steps.first
  end

  # Check if a step is a terminal node
  # @param step [Step] The step to check
  # @return [Boolean]
  def terminal?(step)
    return false unless step
    return true if step.is_a?(Steps::Resolve)
    step.transitions.empty? && !step.is_a?(Steps::SubFlow)
  end

  private

  def resolve_graph_next(step, results)
    transitions = step.transitions.order(:position)
    return nil if transitions.empty?

    # Check universal jumps first
    jump_result = check_jumps(step, results)
    return jump_result if jump_result

    # Evaluate transitions in order, return first match
    transitions.each do |transition|
      target = transition.target_step
      next unless target

      if transition.condition.blank?
        return target
      end

      if ConditionEvaluator.evaluate(transition.condition, results)
        return target
      end
    end

    # Fallback to default (unconditional) transition
    default = transitions.find_by(condition: [nil, ""])
    default&.target_step
  end

  def check_jumps(step, results)
    return nil unless step.jumps.present? && step.jumps.is_a?(Array)

    step.jumps.each do |jump|
      jump_condition = jump["condition"] || jump[:condition]
      jump_next_step_id = jump["next_step_id"] || jump[:next_step_id]

      next unless jump_condition.present? && jump_next_step_id.present?

      condition_result = case step
                         when Steps::Question
                           current_answer = results[step.title] || results[step.variable_name]
                           current_answer.to_s == jump_condition.to_s
                         when Steps::Action
                           jump_condition == "completed" || evaluate_condition(jump_condition, results)
                         else
                           evaluate_condition(jump_condition, results)
                         end

      if condition_result
        target = @workflow.workflow_steps.unscoped.find_by(uuid: jump_next_step_id)
        return target if target
      end
    end

    nil
  end

  def evaluate_condition(condition, results)
    return false if condition.blank?
    ConditionEvaluator.evaluate(condition, results)
  end
end
