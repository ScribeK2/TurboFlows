require 'timeout'

class Scenario < ApplicationRecord
  include ScenarioExecution

  belongs_to :workflow
  belongs_to :user

  # Parent/child scenario associations for sub-flows
  belongs_to :parent_scenario, class_name: 'Scenario', optional: true
  has_many :child_scenarios, class_name: 'Scenario', foreign_key: 'parent_scenario_id', dependent: :destroy

  # Status constants
  STATUSES = %w[active completed stopped timeout error awaiting_subflow].freeze

  # Scenario limits to prevent infinite loops and DoS
  MAX_ITERATIONS = ENV.fetch("SCENARIO_MAX_ITERATIONS", 1000).to_i
  MAX_EXECUTION_TIME = ENV.fetch("SCENARIO_MAX_SECONDS", 30).to_i # seconds
  MAX_CONDITION_DEPTH = 50 # Max nested condition evaluations per step

  # Custom error classes
  class ScenarioTimeout < StandardError; end
  class ScenarioIterationLimit < StandardError; end

  # JSON columns - automatically serialized/deserialized

  # Initialize execution_path and results as empty arrays/hashes if needed
  before_save :initialize_execution_data

  # Validate status
  validates :status, inclusion: { in: STATUSES }, allow_nil: false

  # Track iteration count for step-by-step processing
  attr_accessor :iteration_count

  def initialize_execution_data
    self.execution_path ||= []
    self.results ||= {}
    self.inputs ||= {}
  end

  # Check if workflow is in graph mode
  def graph_mode?
    workflow&.graph_mode? || false
  end

  # Get the current step (works for both linear and graph mode)
  def current_step
    return nil unless workflow&.steps&.present?

    if graph_mode? && current_node_uuid.present?
      workflow.find_step_by_id(current_node_uuid)
    elsif current_step_index < workflow.steps.length
      workflow.steps[current_step_index]
    end
  end

  # Get the current step UUID (graph mode) or generate one (linear mode)
  def current_step_uuid
    if graph_mode?
      current_node_uuid
    else
      current_step&.dig('id')
    end
  end

  # Check if waiting for sub-flow to complete
  def awaiting_subflow?
    status == 'awaiting_subflow'
  end

  # Get the active child scenario (if any)
  def active_child_scenario
    child_scenarios.find_by(status: %w[active awaiting_subflow])
  end

  # Check if scenario is stopped
  def stopped?
    status == 'stopped'
  end

  # Check if scenario is complete
  def complete?
    return true if status == 'completed'
    return true if stopped?
    return false if awaiting_subflow?
    return true unless workflow&.steps&.present?

    if graph_mode?
      # In graph mode, complete when no current node or current node is nil
      current_node_uuid.nil? && status != 'active'
    else
      current_step_index >= workflow.steps.length
    end
  end

  # Stop the workflow execution
  def stop!(step_index = nil)
    update!(
      status: 'stopped',
      stopped_at_step_index: step_index || current_step_index
    )
  end

  # Process a single step and advance
  # Returns false if step can't be processed, true otherwise
  # Raises ScenarioIterationLimit if max iterations exceeded
  def process_step(answer = nil)
    return false if complete?
    return false if stopped?
    return false if %w[timeout error].include?(status)

    # If awaiting sub-flow completion, check child status
    if awaiting_subflow?
      return process_subflow_completion
    end

    step = current_step
    return false unless step

    # Idempotency guard: prevent re-processing the same non-interactive step.
    # Question steps are excluded because users can legitimately re-answer after back navigation.
    if execution_path.present? && step['type'] != 'question'
      last_entry = execution_path.last
      if graph_mode?
        return false if last_entry&.dig('step_uuid') == step['id']
      else
        return false if last_entry&.dig('step_index') == current_step_index
      end
    end

    # Track iterations to prevent infinite loops in step-by-step mode
    self.iteration_count ||= execution_path&.length || 0
    self.iteration_count += 1

    if iteration_count > MAX_ITERATIONS
      self.status = 'error'
      self.results ||= {}
      self.results['_error'] = "Scenario exceeded maximum iterations (#{MAX_ITERATIONS})"
      save
      raise ScenarioIterationLimit, "Scenario exceeded maximum of #{MAX_ITERATIONS} steps"
    end

    # Initialize execution_path if needed
    initialize_execution_data

    # Add step to execution path
    path_entry = build_path_entry(step)

    case step['type']
    when 'question'
      process_question_step(step, answer, path_entry)

    when 'action'
      process_action_step(step, path_entry)

    when 'sub_flow'
      return process_subflow_step(step, path_entry)

    when 'message'
      process_message_step(step, path_entry)

    when 'escalate'
      process_escalate_step(step, path_entry)

    when 'resolve'
      process_resolve_step(step, path_entry)

    else
      # Unknown step type, advance to next
      advance_to_next_step(step)
    end

    # Mark as completed if we've reached the end
    check_completion

    save
  end

  private

  # Build execution path entry for a step
  def build_path_entry(step)
    entry = {
      step_title: step['title'],
      step_type: step['type']
    }

    if graph_mode?
      entry[:step_uuid] = step['id']
    else
      entry[:step_index] = current_step_index
    end

    entry
  end

  # Process a question step
  def process_question_step(step, answer, path_entry)
    input_key = step['variable_name'].presence || current_step_index.to_s
    self.inputs ||= {}
    self.inputs[input_key] = answer if answer.present?
    self.inputs[step['title']] = answer if answer.present?

    self.results ||= {}
    self.results[step['title']] = answer if answer.present?
    self.results[step['variable_name']] = answer if step['variable_name'].present? && answer.present?

    path_entry[:answer] = answer
    self.execution_path << path_entry

    advance_to_next_step(step)
  end

  # Process an action step
  def process_action_step(step, path_entry)
    path_entry[:action_completed] = true
    self.results ||= {}
    self.results[step['title']] = "Action executed"

    # Process output_fields if defined
    if step['output_fields'].present? && step['output_fields'].is_a?(Array)
      step['output_fields'].each do |output_field|
        next unless output_field.is_a?(Hash) && output_field['name'].present?

        variable_name = output_field['name'].to_s
        raw_value = output_field['value'] || ""
        interpolated_value = VariableInterpolator.interpolate(raw_value, self.results)
        self.results[variable_name] = interpolated_value
      end
    end

    self.execution_path << path_entry
    advance_to_next_step(step)
  end

  # Process a message step (Graph Mode)
  # Message steps display information to the CSR and auto-advance
  def process_message_step(step, path_entry)
    path_entry[:message_displayed] = true
    self.results ||= {}
    self.results[step['title']] = "Message displayed"

    # Interpolate content if present
    if step['content'].present?
      path_entry[:content] = VariableInterpolator.interpolate(step['content'], self.results)
    end

    self.execution_path << path_entry
    advance_to_next_step(step)
  end

  # Process an escalate step (Graph Mode)
  # Escalate steps record escalation metadata and can either be terminal or continue
  def process_escalate_step(step, path_entry)
    path_entry[:escalated] = true
    self.results ||= {}
    self.results[step['title']] = "Escalated"

    # Store escalation metadata in results
    self.results['_escalation'] = {
      'type' => step['target_type'],
      'value' => step['target_value'],
      'priority' => step['priority'] || 'normal',
      'reason_required' => step['reason_required'] || false,
      'notes' => step['notes']
    }.compact

    self.execution_path << path_entry
    advance_to_next_step(step)
  end

  # Process a resolve step (Graph Mode)
  # Resolve steps are always terminal and complete the scenario
  def process_resolve_step(step, path_entry)
    path_entry[:resolved] = true
    self.results ||= {}
    self.results[step['title']] = "Issue resolved"

    # Store resolution metadata in results
    self.results['_resolution'] = {
      'type' => step['resolution_type'] || 'success',
      'code' => step['resolution_code'],
      'notes_required' => step['notes_required'] || false,
      'survey_trigger' => step['survey_trigger'] || false
    }.compact

    self.execution_path << path_entry

    # Resolve steps are always terminal - complete the scenario
    self.status = 'completed'
    self.current_node_uuid = nil if graph_mode?
  end

  # Process a sub-flow step - creates child scenario
  def process_subflow_step(step, path_entry)
    target_workflow_id = step['target_workflow_id']
    target_workflow = Workflow.find_by(id: target_workflow_id)

    unless target_workflow
      self.results ||= {}
      self.results['_error'] = "Sub-flow target workflow #{target_workflow_id} not found"
      self.status = 'error'
      save
      return false
    end

    # Save current position for resumption
    self.resume_node_uuid = step['id']

    # Stop any stale active children from previous sub-flow attempts (e.g. back navigation)
    # to prevent active_child_scenario from finding the wrong child later.
    child_scenarios.where(status: %w[active awaiting_subflow]).find_each do |stale_child|
      stale_child.update!(status: 'stopped')
    end

    # Create child scenario with inherited variables
    child_results = self.results.dup || {}

    # Apply variable mapping if defined
    variable_mapping = step['variable_mapping'] || {}
    variable_mapping = JSON.parse(variable_mapping) rescue {} if variable_mapping.is_a?(String)
    variable_mapping = {} unless variable_mapping.is_a?(Hash)
    variable_mapping.each do |parent_var, child_var|
      if self.results&.key?(parent_var)
        child_results[child_var] = self.results[parent_var]
      end
    end

    child_scenario = Scenario.create!(
      workflow: target_workflow,
      user: user,
      parent_scenario: self,
      results: child_results,
      inputs: {},
      status: 'active'
    )

    # Initialize child's starting position
    if target_workflow.graph_mode?
      child_scenario.update!(current_node_uuid: target_workflow.start_node_uuid)
    end

    path_entry[:subflow_started] = true
    path_entry[:child_scenario_id] = child_scenario.id
    path_entry[:target_workflow_title] = target_workflow.title
    self.execution_path << path_entry

    # Mark parent as awaiting sub-flow
    self.status = 'awaiting_subflow'
    save

    true
  end

  public

  # Process completion of a sub-flow
  def process_subflow_completion
    child = active_child_scenario || child_scenarios.where(status: 'completed').order(updated_at: :desc).first

    # If child is still running, wait
    return false if child && !child.complete?

    # Merge child results back to parent
    if child&.results.present?
      self.results ||= {}

      # Get variable mapping from the sub-flow step
      resume_step = workflow.find_step_by_id(resume_node_uuid)
      variable_mapping = resume_step&.dig('variable_mapping') || {}
      variable_mapping = JSON.parse(variable_mapping) rescue {} if variable_mapping.is_a?(String)
      variable_mapping = {} unless variable_mapping.is_a?(Hash)

      # Merge child results back to parent.
      # Explicitly mapped variables always overwrite (that's the intent of the mapping).
      # Non-mapped child results are only added if the key doesn't already exist in the
      # parent — this prevents child step titles / variable names from overwriting parent
      # values that may be used in routing conditions.
      reverse_mapping = variable_mapping.invert
      child.results.each do |key, value|
        next if key.start_with?('_') # Skip internal keys

        if reverse_mapping.key?(key)
          # Explicitly mapped: always overwrite parent value
          self.results[reverse_mapping[key]] = value
        else
          # Non-mapped: only add if parent doesn't already have this key
          self.results[key] = value unless self.results.key?(key)
        end
      end
    end

    # Move to next step after sub-flow
    self.status = 'active'

    if graph_mode?
      resolver = StepResolver.new(workflow)
      resume_step = workflow.find_step_by_id(resume_node_uuid)
      next_uuid = resolver.resolve_next_after_subflow(resume_step, self.results) if resume_step

      # Guard against self-loop: if the resolved next step is the same sub_flow step
      # we just completed, treat it as end-of-workflow rather than looping infinitely.
      if next_uuid == resume_node_uuid
        Rails.logger.warn "[Scenario ##{id}] Sub-flow step #{resume_node_uuid} resolved back to itself — breaking loop"
        advance_to_step_uuid(nil)
      else
        advance_to_step_uuid(next_uuid)
      end
    else
      # Linear mode: advance past the sub-flow step
      resume_step = workflow.find_step_by_id(resume_node_uuid)
      if resume_step
        resume_index = workflow.steps.index(resume_step)
        self.current_step_index = (resume_index || 0) + 1
      end
    end

    self.resume_node_uuid = nil
    check_completion
    save

    true
  end

  private

  # Advance to the next step based on mode
  def advance_to_next_step(step)
    if graph_mode?
      resolver = StepResolver.new(workflow)
      next_uuid = resolver.resolve_next(step, self.results)

      if next_uuid.is_a?(StepResolver::SubflowMarker)
        # Will be handled in next process_step call
        advance_to_step_uuid(next_uuid.step_uuid)
      else
        advance_to_step_uuid(next_uuid)
      end
    else
      next_step_index = determine_next_step_index(step, self.results)
      self.current_step_index = next_step_index
    end
  end

  # Advance to a specific step UUID (graph mode)
  def advance_to_step_uuid(uuid)
    self.current_node_uuid = if uuid.nil?
                               # Reached end of workflow
                               nil
                             else
                               uuid
                             end
  end

  # Check if scenario is complete
  def check_completion
    return if %w[stopped awaiting_subflow].include?(status)

    if graph_mode?
      # Complete if no current node or current node is terminal
      if current_node_uuid.nil?
        self.status = 'completed'
      else
        step = current_step
        if step.nil?
          self.status = 'completed'
        elsif StepResolver.new(workflow).terminal?(step) && step['type'] != 'sub_flow'
          # Terminal node that's not a sub-flow - will complete after processing
        end
      end
    elsif current_step_index >= workflow.steps.length
      self.status = 'completed'
    end
  end

  public

  # Check for universal jumps on any step type
  def check_jumps(step, results)
    return nil unless step['jumps'].present? && step['jumps'].is_a?(Array)

    step['jumps'].each do |jump|
      jump_condition = jump['condition'] || jump[:condition]
      jump_next_step_id = jump['next_step_id'] || jump[:next_step_id]

      next unless jump_condition.present? && jump_next_step_id.present?

      # For question steps, condition might be the answer value
      # For action steps, condition might be 'completed' or similar
      # For decision steps, condition can be complex expressions

      condition_result = case step['type']
                         when 'question'
                           current_answer = results[step['title']] || results[step['variable_name']]
                           current_answer.to_s == jump_condition.to_s
                         when 'action'
                           if jump_condition == 'completed'
                             true
                           else
                             evaluate_condition_string(jump_condition, results)
                           end
                         else
                           evaluate_condition_string(jump_condition, results)
                         end

      next unless condition_result

      next_step = find_step_by_id(jump_next_step_id)
      if next_step
        return workflow.steps.index(next_step)
      end
    end

    nil # No jump matched
  end

  def execute
    return false unless workflow.present? && inputs.present?

    # Wrap execution with timeout protection
    Timeout.timeout(MAX_EXECUTION_TIME, ScenarioTimeout) do
      execute_with_limits
    end
  rescue ScenarioTimeout
    self.status = 'timeout'
    self.results ||= {}
    self.results['_error'] = "Scenario timed out after #{MAX_EXECUTION_TIME} seconds"
    save
    Rails.logger.warn "Scenario #{id} timed out for workflow #{workflow_id}"
    false
  rescue ScenarioIterationLimit
    Rails.logger.warn "Scenario #{id} hit iteration limit for workflow #{workflow_id}"
    false
  end

  private

  def evaluate_condition_string(condition_string, results)
    ConditionEvaluator.evaluate(condition_string, results)
  end

  def evaluate_condition(step, results)
    condition = step['condition']
    return false unless condition.present?

    evaluate_condition_string(condition, results)
  end

  def find_step_by_title(title)
    return nil unless title.present?

    # Exact match first
    step = workflow.steps.find { |s| s['title'] == title }
    return step if step

    # Case-insensitive fallback
    workflow.steps.find { |s| s['title']&.downcase == title.downcase }
  end

  def find_step_by_id(id)
    workflow.steps.find { |s| s['id'] == id }
  end

  # Resolve a step reference (ID or title) to a step object
  # Prefers ID-based lookup but falls back to title for backward compatibility
  # Returns the step hash or nil if not found
  def resolve_step_reference(reference)
    return nil if reference.blank?

    Rails.logger.debug { "[Scenario ##{id}] resolve_step_reference: '#{reference}'" }

    # First try to resolve to ID using workflow's helper (handles both IDs and titles)
    step_id = workflow.resolve_step_reference_to_id(reference)
    if step_id.present?
      step = find_step_by_id(step_id)
      Rails.logger.debug { "[Scenario ##{id}] Resolved via ID: #{step ? step['title'] : 'NOT FOUND'}" }
      return step if step
    end

    # Fallback to title-based lookup for backward compatibility
    step = find_step_by_title(reference)
    Rails.logger.debug { "[Scenario ##{id}] Resolved via title: #{step ? step['title'] : 'NOT FOUND'}" }

    unless step
      Rails.logger.error "[Scenario ##{id}] Could not resolve '#{reference}'. Available: #{workflow.steps.map { |s| s['title'] }}"
    end

    step
  end
end
