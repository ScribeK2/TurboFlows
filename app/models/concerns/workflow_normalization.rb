# Handles variable name extraction and utility methods for workflows.
# JSONB normalization callbacks have been removed — AR Step models
# handle their own validation and normalization.
module WorkflowNormalization
  extend ActiveSupport::Concern

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

  # Extract all variable names from question steps and action output fields
  def variables
    variable_names = []

    # Get variables from question steps
    steps.where(type: "Steps::Question").where.not(variable_name: [nil, ""]).find_each do |step|
      variable_names << step.variable_name
    end

    # Get variables from action step output_fields
    steps.where(type: "Steps::Action").find_each do |step|
      next unless step.output_fields.present? && step.output_fields.is_a?(Array)

      step.output_fields.each do |output_field|
        variable_names << output_field["name"] if output_field.is_a?(Hash) && output_field["name"].present?
      end
    end

    variable_names.compact.uniq
  end
end
