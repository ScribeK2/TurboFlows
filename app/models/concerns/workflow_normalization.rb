# frozen_string_literal: true

# Handles step normalization, variable name generation, and format conversion
# for workflows. Ensures backward compatibility with legacy step formats.
# Also handles graph-mode normalization for DAG-based workflows.
module WorkflowNormalization
  extend ActiveSupport::Concern

  included do
    before_validation :normalize_steps_on_save
    before_validation :normalize_graph_steps, if: :graph_mode?
    before_validation :ensure_start_node_uuid, if: :graph_mode?
  end

  # Ensure all steps have unique IDs
  # This assigns UUIDs to steps that don't have them yet
  def ensure_step_ids
    return unless steps.present?

    steps.each do |step|
      next unless step.is_a?(Hash)

      step['id'] ||= SecureRandom.uuid
    end
  end

  # Auto-generate variable names for question steps that don't have one
  # Uses the step title to create a snake_case variable name
  def ensure_variable_names
    return unless steps.present?

    # Collect existing variable names to avoid conflicts
    existing_names = steps
                     .select { |s| s.is_a?(Hash) && s['variable_name'].present? }
                     .map { |s| s['variable_name'] }

    steps.each do |step|
      next unless step.is_a?(Hash)
      next unless step['type'] == 'question'
      next if step['variable_name'].present?
      next if step['title'].blank?

      # Generate base name from title
      base_name = generate_variable_name(step['title'])
      next if base_name.blank?

      # Ensure uniqueness by appending a number if needed
      final_name = base_name
      counter = 2
      while existing_names.include?(final_name)
        final_name = "#{base_name}_#{counter}"
        counter += 1
      end

      step['variable_name'] = final_name
      existing_names << final_name
    end
  end

  # Generate a valid variable name from a title string
  # Example: "Customer Name" -> "customer_name"
  # Example: "What is your issue?" -> "what_is_your_issue"
  def generate_variable_name(title)
    return nil if title.blank?

    title
      .to_s
      .strip
      .gsub(/[?!.,;:'"(){}\[\]]/, '') # Remove punctuation
      .parameterize(separator: '_') # Convert to snake_case
      .tr('-', '_').squeeze('_') # Collapse multiple underscores
      .gsub(/^_|_$/, '')                # Remove leading/trailing underscores
      .first(30)                        # Limit length
      .gsub(/_$/, '')                   # Remove trailing underscore from truncation
  end

  # Normalize steps to convert legacy format to new format
  # This ensures backward compatibility with old workflows
  # Called before validation to convert old format to new format
  def normalize_steps_on_save
    return unless steps.present?

    # First ensure all steps have IDs
    ensure_step_ids

    # Auto-generate variable names for question steps that don't have one
    ensure_variable_names

    # Filter out completely empty steps (no type, no title, no data)
    # But preserve steps that have data even if type is missing (they're still being filled out)
    self.steps = steps.select do |step|
      step.is_a?(Hash) && (
        step['type'].present? ||
        step['title'].present? ||
        step['description'].present? ||
        step['question'].present? ||
        step['action_type'].present?
      )
    end
  end

  # Returns steps as-is. Legacy decision normalization has been removed.
  def normalized_steps
    steps || []
  end

  # Extract all variable names from question steps
  def variables
    return [] unless steps.present?

    variable_names = []

    # Get variables from question steps
    steps.select { |step| step['type'] == 'question' && step['variable_name'].present? }
         .each { |step| variable_names << step['variable_name'] }

    # Get variables from action step output_fields
    steps.select { |step| step['type'] == 'action' && step['output_fields'].present? && step['output_fields'].is_a?(Array) }
         .each do |step|
           step['output_fields'].each do |output_field|
             variable_names << output_field['name'] if output_field.is_a?(Hash) && output_field['name'].present?
           end
         end

    variable_names.compact.uniq
  end

  # ============================================================================
  # Graph Mode Normalization
  # These methods handle normalization for DAG-based workflows.
  # ============================================================================

  # Normalize graph-mode steps
  # Ensures all transitions have valid structure and target_uuid references
  def normalize_graph_steps
    return unless steps.present?

    steps.map { |s| s['id'] }.compact

    steps.each do |step|
      next unless step.is_a?(Hash)

      # Normalize transitions array
      if step['transitions'].present? && step['transitions'].is_a?(Array)
        step['transitions'] = step['transitions'].map do |transition|
          next nil unless transition.is_a?(Hash)

          normalized = {}

          # Normalize target_uuid (support both string keys and symbol keys)
          target = transition['target_uuid'] || transition[:target_uuid]
          normalized['target_uuid'] = target.to_s if target.present?

          # Normalize condition
          condition = transition['condition'] || transition[:condition]
          normalized['condition'] = condition.to_s.strip if condition.present?

          # Normalize label (optional display name for the transition)
          label = transition['label'] || transition[:label]
          normalized['label'] = label.to_s.strip if label.present?

          # Only include valid transitions with target_uuid
          normalized['target_uuid'].present? ? normalized : nil
        end.compact
      else
        # Initialize empty transitions array for graph mode
        step['transitions'] ||= []
      end

      # For sub_flow steps, normalize target_workflow_id
      next unless step['type'] == 'sub_flow'

      target_id = step['target_workflow_id'] || step[:target_workflow_id]
      step['target_workflow_id'] = target_id.to_i if target_id.present?
      step.delete(:target_workflow_id)

      # Normalize variable_mapping for sub-flows
      # The form submits variable_mapping as a JSON string; parse it if needed.
      if step['variable_mapping'].is_a?(String)
        step['variable_mapping'] = begin
          parsed = JSON.parse(step['variable_mapping'])
          parsed.is_a?(Hash) ? parsed : {}
        rescue JSON::ParserError
          {}
        end
      end
      if step['variable_mapping'].present? && step['variable_mapping'].is_a?(Hash)
        step['variable_mapping'] = step['variable_mapping'].transform_keys(&:to_s)
      end
    end
  end

  # Ensure start_node_uuid is set for graph mode workflows
  def ensure_start_node_uuid
    return unless steps.present?

    if start_node_uuid.blank?
      # Default to first step's ID
      self.start_node_uuid = steps.first&.dig('id')
    elsif find_step_by_id(start_node_uuid).nil?
      # If start_node_uuid references a non-existent step, reset to first step
      self.start_node_uuid = steps.first&.dig('id')
    end
  end
end
