# ScenarioStepProcessor — extracted from Scenario (audit finding M-01)
#
# Handles all step-type-specific processing logic during scenario execution.
# Scenario#process_step delegates to this class, keeping the Scenario model thin.
class ScenarioStepProcessor
  # What processing a step decided.
  #
  # This used to be a bare boolean, which could not carry the one thing a
  # caller most needs to know: that the step refused to advance and why. The
  # validation messages were written into the path_entry hash, which is
  # discarded on the refusing branch, so a run blocked on a required field
  # showed the user nothing at all.
  #
  # :advanced          moved on to another step
  # :resolved          the run ended here
  # :awaiting_subflow  a child scenario is now running
  # :blocked           refused, with messages for the user; nothing was saved
  # :halted            could not run, with a reason the caller may log or ignore
  #
  # `errors` stays the complete list of messages for the user — that contract is
  # what every reader relies on. `field_errors` says which input each one is
  # about, when the step knows: a form does, Escalate and Resolve have one field
  # each and pass nothing. The renderer subtracts, so a message shown under its
  # field is not also shouted from the block above.
  Outcome = Data.define(:status, :errors, :field_errors, :reason) do
    def self.advanced = new(status: :advanced, errors: [], field_errors: {}, reason: nil)
    def self.resolved = new(status: :resolved, errors: [], field_errors: {}, reason: nil)
    def self.awaiting_subflow = new(status: :awaiting_subflow, errors: [], field_errors: {}, reason: nil)

    def self.blocked(errors, field_errors: {})
      new(status: :blocked, errors: Array(errors), field_errors: field_errors, reason: nil)
    end

    def self.halted(reason) = new(status: :halted, errors: [], field_errors: {}, reason: reason)

    def advanced? = status == :advanced
    def resolved? = status == :resolved
    def awaiting_subflow? = status == :awaiting_subflow
    def blocked? = status == :blocked
    def halted? = status == :halted
  end

  # The step body as the agent read it: interpolated, plain text, capped.
  #
  # Stored on the entry rather than fetched from the Step later, because steps
  # are edited and deleted after runs — reading the live record would replay a
  # call with text nobody ever saw, or blow up on a missing uuid.
  #
  # Plain text, not the Action Text markup: a read-only re-read does not need
  # it, and HTML in a json column invites an escaping review with no upside.
  BODY_FIELDS = { "action" => :instructions, "message" => :content }.freeze

  def initialize(scenario)
    @scenario = scenario
  end

  # Dispatch to the correct process_*_step method based on step type.
  # Every branch returns an Outcome.
  def process(step, answer, path_entry, resolved_here: false)
    case step.step_type
    when "question" then process_question_step(step, answer, path_entry)
    when "action"   then process_action_step(step, path_entry, resolved_here: resolved_here)
    when "sub_flow" then process_subflow_step(step, path_entry)
    when "form"     then process_form_step(step, answer, path_entry)
    when "message"  then process_message_step(step, path_entry, resolved_here: resolved_here)
    when "escalate" then process_escalate_step(step, path_entry)
    when "resolve"  then process_resolve_step(step, path_entry)
    else
      @scenario.advance_to_next_step(step)
      Outcome.advanced
    end
  end

  private

  def capture_body(step)
    field = BODY_FIELDS[step.step_type]
    return nil unless field

    rich = step.try(field)
    return nil if rich.blank?

    plain = rich.respond_to?(:to_plain_text) ? rich.to_plain_text : rich.to_s
    VariableInterpolator.interpolate(plain, @scenario.results || {}).truncate(Scenario::ENTRY_TEXT_LIMIT)
  end

  # Process a question step
  def process_question_step(step, answer, path_entry)
    input_key = step.variable_name.presence || @scenario.current_step_index.to_s
    @scenario.inputs ||= {}
    @scenario.inputs[input_key] = answer if answer.present?
    @scenario.inputs[step.title] = answer if answer.present?

    @scenario.results ||= {}
    @scenario.results[step.title] = answer if answer.present?
    @scenario.results[step.variable_name] = answer if step.variable_name.present? && answer.present?

    path_entry["answer"] = answer
    @scenario.append_path_entry(path_entry)

    @scenario.advance_to_next_step(step)
    Outcome.advanced
  end

  # Process a form step — validates field responses, persists a StepResponse, and merges values into results
  def process_form_step(step, answer, path_entry)
    responses = answer.is_a?(Hash) ? answer : {}

    field_errors = step.validate_responses(responses)
    if field_errors.any?
      return Outcome.blocked(field_errors.values.flatten, field_errors: field_errors)
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

    @scenario.append_path_entry(path_entry)
    @scenario.advance_to_next_step(step)
    Outcome.advanced
  end

  # Process an action step
  def process_action_step(step, path_entry, resolved_here: false)
    path_entry["action_completed"] = true
    path_entry["body"] = capture_body(step)
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

    @scenario.append_path_entry(path_entry)

    # Handle mid-step resolution if the agent indicated this step resolved the issue
    if resolved_here && step.can_resolve
      @scenario.resolve_at_current_step(step)
      Outcome.resolved
    else
      @scenario.advance_to_next_step(step)
      Outcome.advanced
    end
  end

  # Process a message step (Graph Mode)
  # Message steps display information to the CSR and auto-advance
  def process_message_step(step, path_entry, resolved_here: false)
    path_entry["message_displayed"] = true
    @scenario.results ||= {}
    @scenario.results[step.title] = "Message displayed"

    path_entry["body"] = capture_body(step)

    @scenario.append_path_entry(path_entry)

    # Handle mid-step resolution if the agent indicated this step resolved the issue
    if resolved_here && step.can_resolve
      @scenario.resolve_at_current_step(step)
      Outcome.resolved
    else
      @scenario.advance_to_next_step(step)
      Outcome.advanced
    end
  end

  # Process an escalate step (Graph Mode)
  # Escalate steps record escalation metadata and can either be terminal or continue
  def process_escalate_step(step, path_entry)
    # Server-side validation: require escalation reason when flag is set
    if step.reason_required
      reason = (@scenario.inputs || {})["escalation_reason"]
      return Outcome.blocked(["Escalation reason is required"]) if reason.blank?
    end

    path_entry["escalated"] = true
    # Where the call went, on the entry rather than only in _escalation, because
    # a transcript row is historical: results carry one _escalation blob that a
    # later escalate step overwrites, and the step record can be edited or
    # deleted after the run.
    path_entry["target_type"] = step.target_type
    path_entry["priority"] = step.priority.presence || "medium"
    @scenario.results ||= {}
    @scenario.results[step.title] = "Escalated"

    # Store escalation metadata in results.
    #
    # The reason is *consumed* here, not just read: it is stashed on inputs by
    # the runner controllers for this one step and has no reader afterwards.
    # Leaving it behind let a later escalate step satisfy its own
    # reason_required check with a value the user typed for a different step —
    # including after backing out of this one.
    escalation_reason = (@scenario.inputs || {}).delete("escalation_reason")
    # The words the agent typed, on the entry for the same reason the target is:
    # _escalation is one blob a later escalate step overwrites, and the reason is
    # consumed off inputs as it is read, so the entry is the only place it
    # survives as a fact about *this* step. The thread also reads it to tell a
    # terminal somebody answered from one nobody was shown.
    path_entry["reason"] = escalation_reason if escalation_reason.present?
    @scenario.results['_escalation'] = {
      'type' => step.target_type,
      'value' => step.target_value,
      'priority' => step.priority || 'medium',
      'reason_required' => step.reason_required || false,
      'reason' => escalation_reason,
      'notes' => step.respond_to?(:notes) ? step.notes&.to_plain_text : nil
    }.compact

    @scenario.append_path_entry(path_entry)
    @scenario.record_completion("escalated")
    @scenario.advance_to_next_step(step)
    Outcome.advanced
  end

  # Process a resolve step (Graph Mode)
  # Resolve steps are always terminal and complete the scenario
  def process_resolve_step(step, path_entry)
    # Server-side validation: require resolution notes when flag is set
    if step.notes_required
      notes = (@scenario.inputs || {})["resolution_notes"]
      return Outcome.blocked(["Resolution notes are required"]) if notes.blank?
    end

    path_entry["resolved"] = true
    path_entry["resolution_type"] = step.resolution_type.presence || "success"
    @scenario.results ||= {}
    @scenario.results[step.title] = "Issue resolved"

    # Store resolution metadata in results. Consumed, for the same reason the
    # escalation reason is — see process_escalate_step.
    resolution_notes = (@scenario.inputs || {}).delete("resolution_notes")
    # As with the escalation reason above: on the entry, because _resolution is
    # overwritten and inputs is consumed. Its absence is also what tells the
    # thread this terminal was walked past rather than answered.
    path_entry["notes"] = resolution_notes if resolution_notes.present?
    @scenario.results['_resolution'] = {
      'type' => step.resolution_type || 'success',
      'code' => step.resolution_code,
      'notes_required' => step.notes_required || false,
      'notes' => resolution_notes,
      'survey_trigger' => step.survey_trigger || false
    }.compact

    @scenario.append_path_entry(path_entry)

    @scenario.record_completion("resolved")
    @scenario.status = 'completed'
    @scenario.current_node_uuid = nil
    Outcome.resolved
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
      return Outcome.halted(:failed)
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

    # purpose and shared_access describe the *run*, not the frame, so a child
    # inherits them.
    #
    # Without purpose, a live run's sub-flow took the column default of
    # "simulation" and was reaped by the 7-day tier while its parent lived for
    # 90 — a completed live run silently lost the answers recorded inside its
    # sub-flow, and flattened_execution_path was left splicing against nothing.
    #
    # Without shared_access, an anonymous visitor following a share link was
    # refused their own run the moment a sub-flow opened.
    child_scenario = Scenario.create!(
      workflow: target_workflow,
      user: @scenario.user,
      parent_scenario: @scenario,
      purpose: @scenario.purpose,
      shared_access: @scenario.shared_access?,
      results: child_results,
      inputs: {},
      status: 'active'
    )

    # Initialize child's starting position
    start_uuid = target_workflow.start_step&.uuid || target_workflow.steps.first&.uuid
    child_scenario.update!(current_node_uuid: start_uuid)

    path_entry["subflow_started"] = true
    path_entry["child_scenario_id"] = child_scenario.id
    path_entry["target_workflow_title"] = target_workflow.title
    @scenario.append_path_entry(path_entry)

    # Mark parent as awaiting sub-flow
    @scenario.status = 'awaiting_subflow'
    begin
      @scenario.save
    rescue ActiveRecord::StaleObjectError
      Rails.logger.warn "[Scenario ##{@scenario.id}] Stale object on subflow await save — concurrent modification detected"
      return Outcome.halted(:conflict)
    end

    Outcome.awaiting_subflow
  end
end
