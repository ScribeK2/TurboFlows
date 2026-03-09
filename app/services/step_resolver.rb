# Resolves the next step in a graph-mode workflow based on current step and results.
# Handles transition condition evaluation and sub-flow detection.
#
# Supports both ActiveRecord Step instances and legacy JSONB step hashes
# during the migration period. The hash path will be removed after
# the JSONB column is dropped.
#
# Usage:
#   resolver = StepResolver.new(workflow)
#   next_step = resolver.resolve_next(current_step, results)
#
# Returns:
#   - Step instance (or UUID string for legacy hash mode) of the next step
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
  # @param step [Step, Hash] The current step (ActiveRecord instance or legacy hash)
  # @param results [Hash] Current scenario results (variable values)
  # @return [Step, String, SubflowMarker, nil]
  def resolve_next(step, results)
    return nil unless step

    if step.is_a?(Step)
      resolve_next_activerecord(step, results)
    else
      resolve_next_legacy(step, results)
    end
  end

  # Resolve the next step after a sub-flow completes
  # @param step [Step, Hash] The sub_flow step that just completed
  # @param results [Hash] Current scenario results
  # @return [Step, String, nil]
  def resolve_next_after_subflow(step, results)
    return nil unless step

    if step.is_a?(Step)
      resolve_graph_next_activerecord(step, results)
    else
      resolve_graph_next_legacy(step, results)
    end
  end

  # Find the start step for this workflow
  # @return [Step, Hash, nil]
  def start_step
    if @workflow.workflow_steps.any?
      @workflow.start_step || @workflow.workflow_steps.first
    else
      @workflow.start_node
    end
  end

  # Check if a step is a terminal node
  # @param step [Step, Hash] The step to check
  # @return [Boolean]
  def terminal?(step)
    return false unless step

    if step.is_a?(Step)
      return true if step.is_a?(Steps::Resolve)
      step.transitions.empty? && !step.is_a?(Steps::SubFlow)
    else
      return true if step["type"] == "resolve"
      transitions = step["transitions"] || []
      transitions.empty? && step["type"] != "sub_flow"
    end
  end

  private

  # ============================================================================
  # ActiveRecord Step path (new)
  # ============================================================================

  def resolve_next_activerecord(step, results)
    if step.is_a?(Steps::SubFlow)
      return SubflowMarker.new(
        target_workflow_id: step.sub_flow_workflow_id,
        variable_mapping: step.variable_mapping || {},
        step_uuid: step.uuid
      )
    end

    resolve_graph_next_activerecord(step, results)
  end

  def resolve_graph_next_activerecord(step, results)
    transitions = step.transitions.order(:position)
    return nil if transitions.empty?

    # Check universal jumps first
    jump_result = check_jumps_activerecord(step, results)
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

  def check_jumps_activerecord(step, results)
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

  # ============================================================================
  # Legacy JSONB Hash path (to be removed after migration)
  # ============================================================================

  def resolve_next_legacy(step, results)
    if step["type"] == "sub_flow"
      return SubflowMarker.new(
        target_workflow_id: step["target_workflow_id"],
        variable_mapping: step["variable_mapping"] || {},
        step_uuid: step["id"]
      )
    end

    resolve_graph_next_legacy(step, results)
  end

  def resolve_graph_next_legacy(step, results)
    transitions = step["transitions"] || []
    return nil if transitions.empty?

    # Check universal jumps first
    jump_result = check_jumps_legacy(step, results)
    return jump_result if jump_result

    transitions.each do |transition|
      target_uuid = transition["target_uuid"]
      next if target_uuid.blank?

      condition = transition["condition"]

      if condition.blank?
        return target_uuid
      end

      if evaluate_condition(condition, results)
        return target_uuid
      end
    end

    default_transition = transitions.find { |t| t["condition"].blank? }
    default_transition&.dig("target_uuid")
  end

  def check_jumps_legacy(step, results)
    return nil unless step["jumps"].present? && step["jumps"].is_a?(Array)

    step["jumps"].each do |jump|
      jump_condition = jump["condition"] || jump[:condition]
      jump_next_step_id = jump["next_step_id"] || jump[:next_step_id]

      next unless jump_condition.present? && jump_next_step_id.present?

      condition_result = case step["type"]
                         when "question"
                           current_answer = results[step["title"]] || results[step["variable_name"]]
                           current_answer.to_s == jump_condition.to_s
                         when "action"
                           jump_condition == "completed" || evaluate_condition(jump_condition, results)
                         else
                           evaluate_condition(jump_condition, results)
                         end

      return jump_next_step_id if condition_result
    end

    nil
  end

  # Shared

  def evaluate_condition(condition, results)
    return false if condition.blank?
    ConditionEvaluator.evaluate(condition, results)
  end
end
