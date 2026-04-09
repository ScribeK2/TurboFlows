class ScenarioNavigator
  def initialize(scenario, workflow)
    @scenario = scenario
    @workflow = workflow
  end

  def go_back
    return unless @scenario.execution_path.present? && @scenario.execution_path.size.positive?

    popped_step = pop_to_interactive_step
    return unless popped_step

    rebuild_state_from_path
    restore_position(popped_step)
    @scenario.status = "active" if @scenario.completed?
    @scenario.save!
  end

  private

  def pop_to_interactive_step
    while @scenario.execution_path.size.positive?
      candidate = @scenario.execution_path.pop
      next if candidate["step_type"] == "sub_flow"

      return candidate
    end
    nil
  end

  def rebuild_state_from_path
    @scenario.results = {}
    @scenario.inputs = {}
    @scenario.execution_path.each do |entry|
      next if entry["answer"].blank?

      step = resolve_step_from_entry(entry)
      next unless step.is_a?(Steps::Question)

      input_key = step.variable_name.presence || (entry["step_index"] || 0).to_s
      @scenario.inputs[input_key] = entry["answer"]
      @scenario.inputs[step.title] = entry["answer"]
      @scenario.results[step.title] = entry["answer"]
      @scenario.results[step.variable_name] = entry["answer"] if step.variable_name.present?
    end
  end

  def resolve_step_from_entry(entry)
    if entry["step_uuid"].present?
      @workflow.find_step_by_uuid(entry["step_uuid"])
    elsif entry["step_index"].present?
      idx = entry["step_index"].to_i
      @workflow.steps.find_by(position: idx) if idx >= 0
    end
  end

  def restore_position(popped_step)
    if popped_step["step_uuid"].present?
      @scenario.current_node_uuid = popped_step["step_uuid"]
    elsif popped_step["step_index"].present?
      @scenario.current_step_index = popped_step["step_index"].to_i
    end
    @scenario.current_step_index = [@scenario.current_step_index.to_i - 1, 0].max
  end
end
