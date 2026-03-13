# Extracted execution logic for Scenario model.
# Contains determine_next_step_index and execute_with_limits.
module ScenarioExecution
  extend ActiveSupport::Concern

  def determine_next_step_index(step, results)
    # Check for universal jumps (works for all step types)
    jump_result = check_jumps(step, results)
    return jump_result if jump_result

    # Default: move to next step
    current_step_index + 1
  end

  # Internal execution method with iteration limits
  def execute_with_limits
    path = []
    results = {}
    current_idx = 0
    iteration_count = 0

    ordered_steps = workflow.workflow_steps.to_a

    while current_idx < ordered_steps.length
      step = ordered_steps[current_idx]
      break unless step

      iteration_count += 1
      if iteration_count > self.class::MAX_ITERATIONS
        self.status = 'error'
        self.results = results.merge('_error' => "Exceeded maximum iterations (#{self.class::MAX_ITERATIONS})")
        self.execution_path = path
        save
        raise Scenario::ScenarioIterationLimit, "Scenario exceeded maximum of #{self.class::MAX_ITERATIONS} iterations"
      end

      path << {
        step_index: current_idx,
        step_title: step.title,
        step_type: step.step_type
      }

      current_idx = execute_step(step, current_idx, path, results)
    end

    record_completion("completed") unless outcome.present?
    self.status = 'completed'
    self.current_step_index = current_idx
    self.execution_path = path
    self.results = results
    save
  rescue StandardError => e
    Rails.logger.error "Scenario execution failed: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    false
  end

  private

  # Execute a single step and return the next step index.
  def execute_step(step, current_step_index, path, results)
    case step.step_type
    when 'question'
      execute_question_step(step, current_step_index, path, results)
    when 'action'
      path.last[:action_completed] = true
      results[step.title] = "Action executed"
      current_step_index + 1
    else
      current_step_index + 1
    end
  end

  def execute_question_step(step, current_step_index, path, results)
    answer = nil
    if step.variable_name.present?
      answer = inputs[step.variable_name]
    end
    answer = inputs[current_step_index.to_s] if answer.blank?
    answer = inputs[step.title] if answer.blank?

    results[step.title] = answer if answer.present?
    results[step.variable_name] = answer if step.variable_name.present? && answer.present?
    path.last[:answer] = answer
    current_step_index + 1
  end

end
