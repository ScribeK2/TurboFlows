# ScenarioStepProcessor — extracted from Scenario (audit finding M-01)
#
# Handles all step-type-specific processing logic during scenario execution.
# Scenario#process_step delegates to this class, keeping the Scenario model thin.
class ScenarioStepProcessor
  def initialize(scenario)
    @scenario = scenario
  end

  # Dispatch to the correct process_*_step method based on step type.
  # Returns the result of the processing method, or calls advance_to_next_step
  # for unknown step types.
  def process(step, answer, path_entry, resolved_here: false)
    case step.step_type
    when "question" then process_question_step(step, answer, path_entry)
    when "action"   then process_action_step(step, path_entry, resolved_here: resolved_here)
    when "sub_flow" then process_subflow_step(step, path_entry)
    when "form"     then process_form_step(step, answer, path_entry)
    when "message"  then process_message_step(step, path_entry, resolved_here: resolved_here)
    when "escalate" then process_escalate_step(step, path_entry)
    when "resolve"  then process_resolve_step(step, path_entry)
    else            @scenario.advance_to_next_step(step)
    end
  end

  private

  # Process a question step
  def process_question_step(step, answer, path_entry)
    input_key = step.variable_name.presence || @scenario.current_step_index.to_s
    @scenario.inputs ||= {}
    @scenario.inputs[input_key] = answer if answer.present?
    @scenario.inputs[step.title] = answer if answer.present?

    @scenario.results ||= {}
    @scenario.results[step.title] = answer if answer.present?
    @scenario.results[step.variable_name] = answer if step.variable_name.present? && answer.present?

    path_entry[:answer] = answer
    @scenario.execution_path << path_entry

    @scenario.advance_to_next_step(step)
  end

  # Process a form step — validates field responses, persists a StepResponse, and merges values into results
  def process_form_step(step, answer, path_entry)
    responses = answer.is_a?(Hash) ? answer : {}

    validation_errors = step.validate_responses(responses)
    if validation_errors.any?
      # Store errors on the path entry so the view can display them, but don't advance
      path_entry["form_errors"] = validation_errors
      return false
    end

    StepResponse.create!(
      scenario: @scenario,
      step: step,
      responses: responses,
      submitted_at: Time.current
    )

    path_entry["form_submitted"] = true
    path_entry["response_summary"] = responses.map { |k, v| "#{k}: #{v}" }.join(", ").truncate(200)

    responses.each { |k, v| (@scenario.results ||= {})[k] = v }

    @scenario.execution_path << path_entry
    @scenario.advance_to_next_step(step)
  end

  # Process an action step
  def process_action_step(step, path_entry, resolved_here: false)
    path_entry[:action_completed] = true
    @scenario.results ||= {}
    @scenario.results[step.title] = "Action executed"

    # Process output_fields if defined
    if step.output_fields.present? && step.output_fields.is_a?(Array)
      step.output_fields.each do |output_field|
        next unless output_field.is_a?(Hash) && output_field['name'].present?

        variable_name = output_field['name'].to_s
        raw_value = output_field['value'] || ""
        interpolated_value = VariableInterpolator.interpolate(raw_value, @scenario.results)
        @scenario.results[variable_name] = interpolated_value
      end
    end

    @scenario.execution_path << path_entry

    # Handle mid-step resolution if the agent indicated this step resolved the issue
    if resolved_here && step.can_resolve
      @scenario.resolve_at_current_step(step)
    else
      @scenario.advance_to_next_step(step)
    end
  end

  # Process a message step (Graph Mode)
  # Message steps display information to the CSR and auto-advance
  def process_message_step(step, path_entry, resolved_here: false)
    path_entry[:message_displayed] = true
    @scenario.results ||= {}
    @scenario.results[step.title] = "Message displayed"

    # Interpolate content if present (Action Text or plain string)
    content_text = step.respond_to?(:content) && step.content.present? ? step.content.to_plain_text : nil
    if content_text.present?
      path_entry[:content] = VariableInterpolator.interpolate(content_text, @scenario.results)
    end

    @scenario.execution_path << path_entry

    # Handle mid-step resolution if the agent indicated this step resolved the issue
    if resolved_here && step.can_resolve
      @scenario.resolve_at_current_step(step)
    else
      @scenario.advance_to_next_step(step)
    end
  end

  # Process an escalate step (Graph Mode)
  # Escalate steps record escalation metadata and can either be terminal or continue
  def process_escalate_step(step, path_entry)
    # Server-side validation: require escalation reason when flag is set
    if step.reason_required
      reason = (@scenario.inputs || {})["escalation_reason"]
      if reason.blank?
        path_entry["escalation_errors"] = ["Escalation reason is required"]
        return false
      end
    end

    path_entry[:escalated] = true
    @scenario.results ||= {}
    @scenario.results[step.title] = "Escalated"

    # Store escalation metadata in results
    escalation_reason = (@scenario.inputs || {})["escalation_reason"]
    @scenario.results['_escalation'] = {
      'type' => step.target_type,
      'value' => step.target_value,
      'priority' => step.priority || 'medium',
      'reason_required' => step.reason_required || false,
      'reason' => escalation_reason,
      'notes' => step.respond_to?(:notes) ? step.notes&.to_plain_text : nil
    }.compact

    @scenario.execution_path << path_entry
    @scenario.record_completion("escalated")
    @scenario.advance_to_next_step(step)
  end

  # Process a resolve step (Graph Mode)
  # Resolve steps are always terminal and complete the scenario
  def process_resolve_step(step, path_entry)
    # Server-side validation: require resolution notes when flag is set
    if step.notes_required
      notes = (@scenario.inputs || {})["resolution_notes"]
      if notes.blank?
        path_entry["resolution_errors"] = ["Resolution notes are required"]
        return false
      end
    end

    path_entry[:resolved] = true
    @scenario.results ||= {}
    @scenario.results[step.title] = "Issue resolved"

    # Store resolution metadata in results
    resolution_notes = (@scenario.inputs || {})["resolution_notes"]
    @scenario.results['_resolution'] = {
      'type' => step.resolution_type || 'success',
      'code' => step.resolution_code,
      'notes_required' => step.notes_required || false,
      'notes' => resolution_notes,
      'survey_trigger' => step.survey_trigger || false
    }.compact

    @scenario.execution_path << path_entry

    @scenario.record_completion("resolved")
    @scenario.status = 'completed'
    @scenario.current_node_uuid = nil
  end

  # Process a sub-flow step - creates child scenario
  def process_subflow_step(step, path_entry)
    target_workflow_id = step.sub_flow_workflow_id
    target_workflow = Workflow.find_by(id: target_workflow_id)

    unless target_workflow
      @scenario.results ||= {}
      @scenario.results['_error'] = "Sub-flow target workflow #{target_workflow_id} not found"
      @scenario.status = 'error'
      begin
        @scenario.save
      rescue ActiveRecord::StaleObjectError
        Rails.logger.warn "[Scenario ##{@scenario.id}] Stale object on subflow error save — concurrent modification detected"
      end
      return false
    end

    # Save current position for resumption
    @scenario.resume_node_uuid = step.uuid

    # Stop any stale active children from previous sub-flow attempts (e.g. back navigation)
    # to prevent active_child_scenario from finding the wrong child later.
    @scenario.child_scenarios.where(status: %w[active awaiting_subflow]).find_each do |stale_child|
      stale_child.update!(status: 'stopped')
    end

    # Create child scenario with inherited variables
    child_results = (@scenario.results || {}).dup

    # Apply variable mapping if defined
    variable_mapping = step.variable_mapping || {}
    if variable_mapping.is_a?(String)
      variable_mapping = begin
        JSON.parse(variable_mapping)
      rescue JSON::ParserError
        {}
      end
    end
    variable_mapping = {} unless variable_mapping.is_a?(Hash)
    variable_mapping.each do |parent_var, child_var|
      if @scenario.results&.key?(parent_var)
        child_results[child_var] = @scenario.results[parent_var]
      end
    end

    child_scenario = Scenario.create!(
      workflow: target_workflow,
      user: @scenario.user,
      parent_scenario: @scenario,
      results: child_results,
      inputs: {},
      status: 'active'
    )

    # Initialize child's starting position
    start_uuid = target_workflow.start_step&.uuid || target_workflow.steps.first&.uuid
    child_scenario.update!(current_node_uuid: start_uuid)

    path_entry[:subflow_started] = true
    path_entry[:child_scenario_id] = child_scenario.id
    path_entry[:target_workflow_title] = target_workflow.title
    @scenario.execution_path << path_entry

    # Mark parent as awaiting sub-flow
    @scenario.status = 'awaiting_subflow'
    begin
      @scenario.save
    rescue ActiveRecord::StaleObjectError
      Rails.logger.warn "[Scenario ##{@scenario.id}] Stale object on subflow await save — concurrent modification detected"
      return false
    end

    true
  end
end
