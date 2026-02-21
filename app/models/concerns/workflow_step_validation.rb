module WorkflowStepValidation
  extend ActiveSupport::Concern

  included do
    validate :validate_steps
    validate :validate_workflow_size
  end

  # Validate step references (public so tests / controller code can call directly)
  def validate_step_references
    true
  end

  private

  def validate_steps
    return unless steps.present?

    # Filter out steps with empty type (they're incomplete and shouldn't be validated)
    # This prevents errors when users are still filling out forms
    valid_steps = steps.select { |step| step.is_a?(Hash) && step['type'].present? && step['type'].strip.present? }

    valid_steps.each_with_index do |step, index|
      step_num = index + 1

      # Skip validation for imported incomplete steps (they'll be fixed by the user)
      next if step['_import_incomplete'] == true

      # Validate step has required fields
      unless step.is_a?(Hash)
        errors.add(:steps, "Step #{step_num}: Invalid step format")
        next
      end

      # Validate step type
      unless self.class::VALID_STEP_TYPES.include?(step['type'])
        errors.add(:steps, "Step #{step_num}: Invalid step type '#{step['type']}'")
        next
      end

      # Validate title (required for all steps)
      if step['title'].blank?
        errors.add(:steps, "Step #{step_num}: Title is required")
      end

      # Type-specific validation
      case step['type']
      when 'question'  then validate_question_step(step, step_num)
      when 'action'    then validate_action_step(step, step_num)
      when 'sub_flow'  then validate_sub_flow_step(step, step_num)
      when 'message'   then validate_message_step(step, step_num)
      when 'escalate'  then validate_escalate_step(step, step_num)
      when 'resolve'   then validate_resolve_step(step, step_num)
      end
    end

    # Validate step references
    validate_step_references
  end

  def validate_question_step(step, step_num)
    if step['question'].blank?
      errors.add(:steps, "Step #{step_num}: Question text is required")
    end
    validate_jumps(step, step_num)
  end

  def validate_action_step(step, step_num)
    validate_jumps(step, step_num)

    if step['output_fields'].present?
      if step['output_fields'].is_a?(Array)
        step['output_fields'].each_with_index do |field, field_index|
          if field.is_a?(Hash)
            if field['name'].blank?
              errors.add(:steps, "Step #{step_num}, Output Field #{field_index + 1}: name is required")
            end
          else
            errors.add(:steps, "Step #{step_num}, Output Field #{field_index + 1}: must be a hash")
          end
        end
      else
        errors.add(:steps, "Step #{step_num}: output_fields must be an array")
      end
    end
  end

  def validate_sub_flow_step(step, step_num)
    validate_jumps(step, step_num)

    if graph_mode? && step['transitions'].present?
      validate_graph_transitions(step, step_num)
    end
  end

  def validate_message_step(step, step_num)
    validate_jumps(step, step_num) if step['jumps'].present?
  end

  def validate_escalate_step(step, step_num)
    if step['target_type'].present? && !%w[team queue supervisor channel department ticket].include?(step['target_type'])
      errors.add(:steps, "Step #{step_num}: Invalid escalation target type '#{step['target_type']}'")
    end
    if step['priority'].present? && !%w[low medium normal high urgent critical].include?(step['priority'])
      errors.add(:steps, "Step #{step_num}: Invalid escalation priority '#{step['priority']}'")
    end
  end

  def validate_resolve_step(step, step_num)
    if step['resolution_type'].present? && !%w[success failure cancelled escalated transferred other transfer ticket manager_escalation].include?(step['resolution_type'])
      errors.add(:steps, "Step #{step_num}: Invalid resolution type '#{step['resolution_type']}'")
    end
    if graph_mode? && step['transitions'].present? && step['transitions'].any?
      errors.add(:steps, "Step #{step_num}: Resolve steps cannot have outgoing transitions")
    end
  end

  def valid_condition_format?(condition)
    ConditionEvaluator.valid?(condition)
  end

  # Validate graph-mode transitions for a step
  def validate_graph_transitions(step, step_num)
    transitions = step['transitions']
    return unless transitions.present? && transitions.is_a?(Array)

    step_ids = steps.map { |s| s['id'] }.compact

    transitions.each_with_index do |transition, transition_index|
      unless transition.is_a?(Hash)
        errors.add(:steps, "Step #{step_num}, Transition #{transition_index + 1}: must be an object")
        next
      end

      target_uuid = transition['target_uuid']
      if target_uuid.blank?
        errors.add(:steps, "Step #{step_num}, Transition #{transition_index + 1}: target_uuid is required")
        next
      end

      unless step_ids.include?(target_uuid)
        errors.add(:steps, "Step #{step_num}, Transition #{transition_index + 1}: references non-existent step ID: #{target_uuid}")
      end

      # Validate condition if present
      condition = transition['condition']
      if condition.present? && !valid_condition_format?(condition)
        errors.add(:steps, "Step #{step_num}, Transition #{transition_index + 1}: Invalid condition format")
      end
    end
  end

  def validate_jumps(step, step_num)
    return unless step['jumps'].present?

    unless step['jumps'].is_a?(Array)
      errors.add(:steps, "Step #{step_num}: jumps must be an array")
      return
    end

    step['jumps'].each_with_index do |jump, jump_index|
      unless jump.is_a?(Hash)
        errors.add(:steps, "Step #{step_num}, Jump #{jump_index + 1}: must be an object")
        next
      end

      # Allow empty jumps (user is still configuring)
      next unless jump['condition'].present? || jump['next_step_id'].present?

      # If either field is present, both should be present
      if jump['condition'].blank?
        errors.add(:steps, "Step #{step_num}, Jump #{jump_index + 1}: condition is required when next_step_id is specified")
      end

      if jump['next_step_id'].blank?
        errors.add(:steps, "Step #{step_num}, Jump #{jump_index + 1}: next_step_id is required when condition is specified")
      end

      # Validate that next_step_id references a valid step
      next unless jump['next_step_id'].present?

      referenced_step = steps.find { |s| s['id'] == jump['next_step_id'] }
      if referenced_step.nil?
        errors.add(:steps, "Step #{step_num}, Jump #{jump_index + 1}: references non-existent step ID: #{jump['next_step_id']}")
      end
    end
  end

  # Validate workflow size limits to prevent DoS and ensure performance
  def validate_workflow_size
    return unless steps.present?

    # Check step count
    if steps.length > self.class::MAX_STEPS
      errors.add(:steps, "Workflow cannot exceed #{self.class::MAX_STEPS} steps (currently #{steps.length})")
      return # Skip other validations if way too many steps
    end

    # Check total JSON size
    begin
      steps_json = steps.to_json
      if steps_json.bytesize > self.class::MAX_TOTAL_STEPS_SIZE
        size_mb = (steps_json.bytesize / 1_000_000.0).round(2)
        max_mb = (self.class::MAX_TOTAL_STEPS_SIZE / 1_000_000.0).round(2)
        errors.add(:steps, "Total workflow data is too large (#{size_mb}MB, max #{max_mb}MB)")
        return
      end
    rescue StandardError
      errors.add(:steps, "Invalid step data format")
      return
    end

    # Check individual step content sizes
    steps.each_with_index do |step, index|
      next unless step.is_a?(Hash)

      step_num = index + 1

      # Check title length
      if step['title'].present? && step['title'].to_s.length > self.class::MAX_STEP_TITLE_LENGTH
        errors.add(:steps, "Step #{step_num}: Title is too long (max #{self.class::MAX_STEP_TITLE_LENGTH} characters)")
      end

      # Check large text fields
      large_fields = %w[description question instructions]
      large_fields.each do |field|
        next unless step[field].present? && step[field].to_s.bytesize > self.class::MAX_STEP_CONTENT_LENGTH

        size_kb = (step[field].to_s.bytesize / 1000.0).round(1)
        max_kb = (self.class::MAX_STEP_CONTENT_LENGTH / 1000.0).round(1)
        errors.add(:steps, "Step #{step_num}: #{field.humanize} is too large (#{size_kb}KB, max #{max_kb}KB)")
      end

      # Check options array size (for multiple choice questions)
      if step['options'].is_a?(Array) && step['options'].length > 100
        errors.add(:steps, "Step #{step_num}: Too many options (max 100)")
      end

      # Check jumps array size
      if step['jumps'].is_a?(Array) && step['jumps'].length > 50
        errors.add(:steps, "Step #{step_num}: Too many jumps (max 50)")
      end
    end
  end
end
