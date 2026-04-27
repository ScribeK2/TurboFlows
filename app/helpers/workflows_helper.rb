# Workflow View Helpers
module WorkflowsHelper
  include StepTypeIcons
  include RailsIcons::Helpers::IconHelper

  # ============================================================================
  # Step Type Helpers
  # ============================================================================

  # Step type → Heroicon name (24/outline). Single source of truth for which
  # Heroicon represents each step type — change here to update everywhere.
  STEP_TYPE_ICONS = {
    'question' => 'question-mark-circle',
    'action' => 'bolt',
    'sub_flow' => 'arrows-right-left',
    'message' => 'chat-bubble-bottom-center-text',
    'escalate' => 'exclamation-triangle',
    'resolve' => 'check-circle',
    'form' => 'document-text'
  }.freeze

  DEFAULT_STEP_ICON = 'document'.freeze

  STEP_TYPE_LABELS = {
    'question' => 'Question',
    'action' => 'Action',
    'message' => 'Message',
    'sub_flow' => 'Sub-flow',
    'escalate' => 'Escalate',
    'resolve' => 'Resolve',
    'form' => 'Form'
  }.freeze

  STEP_TYPE_BADGE_CLASSES = {
    'question' => 'badge--question',
    'action' => 'badge--action',
    'message' => 'badge--message',
    'sub_flow' => 'badge--sub-flow',
    'escalate' => 'badge--escalate',
    'resolve' => 'badge--resolve',
    'form' => 'badge--form'
  }.freeze

  ANSWER_TYPE_LABELS = {
    'yes_no' => 'Yes / No',
    'multiple_choice' => 'Multiple Choice',
    'text' => 'Text Input',
    'number' => 'Number',
    'dropdown' => 'Dropdown'
  }.freeze

  # Get a user-friendly label for a step type
  def step_type_label(type)
    STEP_TYPE_LABELS[type] || type&.titleize || 'Step'
  end

  # Render the Heroicon for a given step type. Delegates to rails_icons.
  def step_type_svg_icon(type, css_classes: "icon")
    icon STEP_TYPE_ICONS.fetch(type, DEFAULT_STEP_ICON), class: css_classes
  end

  private

  # Get CSS classes for a step type badge
  def step_type_badge_classes(type)
    modifier = STEP_TYPE_BADGE_CLASSES[type] || 'badge--default'
    "badge #{modifier}"
  end

  # ============================================================================
  # Answer Type Helpers
  # ============================================================================

  # Get a user-friendly label for an answer type
  def answer_type_label(type)
    ANSWER_TYPE_LABELS[type] || type&.titleize || 'Unknown'
  end

  # ============================================================================
  # Condition Display Helpers
  # ============================================================================

  # Format a condition for human-readable display
  # Converts "variable == 'value'" to "variable is value"
  def format_condition_for_display(condition)
    return 'Not set' if condition.blank?

    # Parse the condition
    if (match = condition.match(/^(\w+)\s*(==|!=|>|>=|<|<=)\s*['"]?([^'"]*?)['"]?$/))
      variable, operator, value = match.captures

      operator_text = case operator
                      when '==' then 'is'
                      when '!=' then 'is not'
                      when '>' then 'is greater than'
                      when '>=' then 'is at least'
                      when '<' then 'is less than'
                      when '<=' then 'is at most'
                      else operator
                      end

      "#{variable} #{operator_text} \"#{value}\""
    else
      condition
    end
  end

  # Get CSS classes for the condition display
  def condition_display_classes(condition)
    if condition.present?
      "text-sm font-medium"
    else
      "text-sm is-disabled"
    end
  end

  # ============================================================================
  # Step Reference Helpers
  # ============================================================================

  # Resolve a step reference (ID or title) to a display name
  def resolve_step_reference(workflow, reference)
    return nil if reference.blank? || workflow.nil?

    title = workflow.resolve_step_reference_to_title(reference)
    title || reference
  end

  # Get step options for a select dropdown
  # Returns an array of [display_name, value] pairs
  def step_options_for_select(workflow, exclude_step_id: nil)
    return [] unless workflow&.steps&.any?

    workflow.steps.order(:position).map.with_index do |step, index|
      next nil if step.title.blank?
      next nil if exclude_step_id && step.uuid == exclude_step_id

      [
        "#{step_type_icon(step.step_type)} #{index + 1}. #{step.title}",
        step.title
      ]
    end.compact
  end

  # ============================================================================
  # Variable Helpers
  # ============================================================================

  # Get variable options for a select dropdown
  # Returns an array of [display_name, value] pairs
  def variable_options_for_select(workflow)
    return [] unless workflow.respond_to?(:variables_with_metadata)

    workflow.variables_with_metadata.map do |var|
      [var[:display_name], var[:name]]
    end
  end

  # Get the answer type for a variable
  def variable_answer_type(workflow, variable_name)
    return nil unless workflow.respond_to?(:variables_with_metadata)

    var = workflow.variables_with_metadata.find { |v| v[:name] == variable_name }
    var&.dig(:answer_type)
  end

  # ============================================================================
  # Workflow Icon
  # ============================================================================

  # Returns a simple workflow/flowchart SVG icon colored by the dominant step type.
  def workflow_list_icon(workflow)
    dominant = workflow.dominant_step_type || 'question'
    hue_var = "--hue-#{dominant == 'sub_flow' ? 'subflow' : dominant}"

    content_tag(:div, class: "wf-list-item__icon", style: "--step-hue: var(#{hue_var});") do
      icon "clipboard-document-check", class: "wf-list-item__icon-svg"
    end
  end
end
