# Extracted execution logic for Simulation model.
# Contains determine_next_step_index and execute_with_limits.
module SimulationExecution
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
    current_step_index = 0
    iteration_count = 0

    while current_step_index < workflow.steps.length
      step = workflow.steps[current_step_index]
      break unless step

      iteration_count += 1
      if iteration_count > self.class::MAX_ITERATIONS
        self.status = 'error'
        self.results = results.merge('_error' => "Exceeded maximum iterations (#{self.class::MAX_ITERATIONS})")
        self.execution_path = path
        save
        raise Simulation::SimulationIterationLimit, "Simulation exceeded maximum of #{self.class::MAX_ITERATIONS} iterations"
      end

      path << {
        step_index: current_step_index,
        step_title: step['title'],
        step_type: step['type']
      }

      current_step_index = execute_step(step, current_step_index, path, results)
    end

    self.status = 'completed'
    self.current_step_index = current_step_index
    self.execution_path = path
    self.results = results
    save
  rescue StandardError => e
    Rails.logger.error "Simulation execution failed: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    false
  end

  private

  # Execute a single step and return the next step index.
  def execute_step(step, current_step_index, path, results)
    case step['type']
    when 'question'
      execute_question_step(step, current_step_index, path, results)
    when 'action'
      path.last[:action_completed] = true
      results[step['title']] = "Action executed"
      current_step_index + 1
    else
      current_step_index + 1
    end
  end

  def execute_question_step(step, current_step_index, path, results)
    answer = nil
    if step['variable_name'].present?
      answer = inputs[step['variable_name']]
    end
    answer = inputs[current_step_index.to_s] if answer.blank?
    answer = inputs[step['title']] if answer.blank?

    results[step['title']] = answer if answer.present?
    results[step['variable_name']] = answer if step['variable_name'].present? && answer.present?
    path.last[:answer] = answer
    current_step_index + 1
  end

end
