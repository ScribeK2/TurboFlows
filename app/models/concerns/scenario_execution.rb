# Extracted execution logic for Scenario model.
# Contains determine_next_step_index and execute_with_limits.
module ScenarioExecution
  extend ActiveSupport::Concern

  # Record the moment a step is displayed to the user.
  # The timestamp is stored as a pending attr_accessor and consumed by build_path_entry.
  def record_step_started
    self.step_started_at_pending = Time.current.iso8601(3)
  end

  # Record the moment a user advances past the current step.
  # Stamps ended_at and duration_seconds on the last execution_path entry.
  def record_step_ended
    return if execution_path.blank?

    last_entry = execution_path.last
    return unless last_entry && last_entry["started_at"].present?

    now = Time.current
    last_entry["ended_at"] = now.iso8601(3)
    started = Time.zone.parse(last_entry["started_at"])
    last_entry["duration_seconds"] = (now - started).round(1)
    begin
      save!(touch: false)
    rescue ActiveRecord::StaleObjectError
      Rails.logger.warn "[Scenario ##{id}] Stale object on record_step_ended — timing data lost (non-critical)"
    end
  end

  def determine_next_step_index(step, results)
    # Delegate jump evaluation to StepResolver (the canonical implementation)
    resolver = StepResolver.new(workflow)
    jump_target = resolver.send(:check_jumps, step, results)
    return jump_target.position if jump_target.is_a?(Step)

    # Default: move to next step
    current_step_index + 1
  end

  # Internal execution method with iteration limits
  def execute_with_limits
    path = []
    results = {}
    current_idx = 0
    iteration_count = 0

    ordered_steps = workflow.steps.to_a

    while current_idx < ordered_steps.length
      step = ordered_steps[current_idx]
      break unless step

      iteration_count += 1
      if iteration_count > self.class::MAX_ITERATIONS
        self.status = 'error'
        self.results = results.merge('_error' => "Exceeded maximum iterations (#{self.class::MAX_ITERATIONS})")
        self.execution_path = path
        save!
        raise Scenario::ScenarioIterationLimit, "Scenario exceeded maximum of #{self.class::MAX_ITERATIONS} iterations"
      end

      path << {
        step_index: current_idx,
        step_title: step.title,
        step_type: step.step_type
      }

      current_idx = execute_step(step, current_idx, path, results)
    end

    record_completion("completed") if outcome.blank?
    self.status = 'completed'
    self.current_step_index = current_idx
    self.execution_path = path
    self.results = results
    save!
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
    when 'form'
      path.last[:form_submitted] = true
      results[step.title] = "Form submitted"
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
