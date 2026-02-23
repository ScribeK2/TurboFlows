# Workflow View Helpers
module WorkflowsHelper
  include StepTypeIcons

  # ============================================================================
  # Step Type Helpers
  # ============================================================================

  # SVG path data for step type icons (Heroicons-style, 24x24, stroke-based)
  STEP_TYPE_SVG_PATHS = {
    'question' => "M8.228 9c.549-1.165 2.03-2 3.772-2 2.21 0 4 1.343 4 3 0 1.4-1.278 2.575-3.006 2.907-.542.104-.994.54-.994 1.093m0 3h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z",
    'action' => "M13 10V3L4 14h7v7l9-11h-7z",
    'sub_flow' => "M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1",
    'message' => "M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z",
    'escalate' => "M5 10l7-7m0 0l7 7m-7-7v18",
    'resolve' => "M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
  }.freeze

  DEFAULT_STEP_SVG_PATH = "M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"

  # SVG path data for UI icons
  UI_SVG_PATHS = {
    'sparkles' => "M5 3v4M3 5h4M6 17v4m-2-2h4m5-16l2.286 6.857L21 12l-5.714 2.143L13 21l-2.286-6.857L5 12l5.714-2.143L13 3z",
    'lightbulb' => "M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z",
    'warning' => "M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z",
    'paperclip' => "M15.172 7l-6.586 6.586a2 2 0 102.828 2.828l6.414-6.586a4 4 0 00-5.656-5.656l-6.415 6.585a6 6 0 108.486 8.486L20.5 13",
    'question' => "M8.228 9c.549-1.165 2.03-2 3.772-2 2.21 0 4 1.343 4 3 0 1.4-1.278 2.575-3.006 2.907-.542.104-.994.54-.994 1.093m0 3h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z",
    'pencil' => "M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z",
    'check_circle' => "M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
  }.freeze

  # Get a user-friendly label for a step type
  def step_type_label(type)
    case type
    when 'question' then 'Question'
    when 'action' then 'Action'
    when 'message' then 'Message'
    when 'sub_flow' then 'Sub-flow'
    when 'escalate' then 'Escalate'
    when 'resolve' then 'Resolve'
    else type&.titleize || 'Step'
    end
  end

  # Get an inline SVG icon for a step type
  def step_type_svg_icon(type, css_classes: "w-5 h-5")
    path_data = STEP_TYPE_SVG_PATHS[type] || DEFAULT_STEP_SVG_PATH
    render_svg_icon(path_data, css_classes: css_classes)
  end

  # Get an inline SVG icon for a UI element
  def ui_svg_icon(name, css_classes: "w-5 h-5")
    path_data = UI_SVG_PATHS[name.to_s]
    return "" unless path_data

    render_svg_icon(path_data, css_classes: css_classes)
  end

  private

  # Render an inline SVG from path data (handles multi-subpath icons)
  def render_svg_icon(path_data, css_classes: "w-5 h-5")
    sub_paths = path_data.split(/(?= M)/).map(&:strip)
    path_elements = sub_paths.map do |d|
      tag.path(d: d, 'stroke-linecap': "round", 'stroke-linejoin': "round", 'stroke-width': "2")
    end.join.html_safe

    tag.svg(
      path_elements,
      class: css_classes,
      fill: "none",
      stroke: "currentColor",
      viewBox: "0 0 24 24",
      xmlns: "http://www.w3.org/2000/svg"
    )
  end

  # Get CSS classes for a step type badge
  def step_type_badge_classes(type)
    base = "inline-flex items-center px-2 py-1 rounded-full text-xs font-medium"

    case type
    when 'question'
      "#{base} bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-300"
    when 'action'
      "#{base} bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400"
    when 'message'
      "#{base} bg-purple-100 text-purple-700 dark:bg-purple-900/30 dark:text-purple-400"
    when 'sub_flow'
      "#{base} bg-indigo-100 text-indigo-700 dark:bg-indigo-900/30 dark:text-indigo-300"
    when 'escalate'
      "#{base} bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-300"
    when 'resolve'
      "#{base} bg-emerald-100 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-300"
    else
      "#{base} bg-gray-100 text-gray-700 dark:bg-gray-900/30 dark:text-gray-300"
    end
  end

  # ============================================================================
  # Answer Type Helpers
  # ============================================================================

  # Get a user-friendly label for an answer type
  def answer_type_label(type)
    case type
    when 'yes_no' then 'Yes / No'
    when 'multiple_choice' then 'Multiple Choice'
    when 'text' then 'Text Input'
    when 'number' then 'Number'
    when 'dropdown' then 'Dropdown'
    else type&.titleize || 'Unknown'
    end
  end

  # ============================================================================
  # Condition Display Helpers
  # ============================================================================

  # Format a condition for human-readable display
  # Converts "variable == 'value'" to "variable is value"
  def format_condition_for_display(condition)
    return 'Not set' if condition.blank?

    # Parse the condition
    if match = condition.match(/^(\w+)\s*(==|!=|>|>=|<|<=)\s*['"]?([^'"]*?)['"]?$/)
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
      "text-sm font-mono text-gray-900 dark:text-gray-100"
    else
      "text-sm text-gray-400 dark:text-gray-500 italic"
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
    return [] unless workflow&.steps.present?

    workflow.steps.map.with_index do |step, index|
      next nil unless step.is_a?(Hash) && step['title'].present?
      next nil if exclude_step_id && step['id'] == exclude_step_id

      [
        "#{step_type_icon(step['type'])} #{index + 1}. #{step['title']}",
        step['title'] # Use title for now, can switch to ID after migration
      ]
    end.compact
  end

  # ============================================================================
  # Variable Helpers
  # ============================================================================

  # Get variable options for a select dropdown
  # Returns an array of [display_name, value] pairs
  def variable_options_for_select(workflow)
    return [] unless workflow&.respond_to?(:variables_with_metadata)

    workflow.variables_with_metadata.map do |var|
      [var[:display_name], var[:name]]
    end
  end

  # Get the answer type for a variable
  def variable_answer_type(workflow, variable_name)
    return nil unless workflow&.respond_to?(:variables_with_metadata)

    var = workflow.variables_with_metadata.find { |v| v[:name] == variable_name }
    var&.dig(:answer_type)
  end

  # ============================================================================
  # Step Type Composition Dots
  # ============================================================================

  # Renders small colored dots representing the composition of step types in a workflow.
  # Groups steps by type and shows up to 4 dots per type. Returns nil if no steps.
  def step_type_composition_dots(workflow)
    steps = workflow.steps
    return nil if steps.blank?

    dot_colors = {
      'question' => 'bg-blue-500',
      'action' => 'bg-emerald-500',
      'message' => 'bg-cyan-500',
      'escalate' => 'bg-red-500',
      'resolve' => 'bg-green-500',
      'sub_flow' => 'bg-indigo-500'
    }

    dot_labels = {
      'question' => 'Question',
      'action' => 'Action',
      'message' => 'Message',
      'escalate' => 'Escalate',
      'resolve' => 'Resolve',
      'sub_flow' => 'Sub-flow'
    }

    # Group steps by type and count them
    type_counts = steps.each_with_object(Hash.new(0)) do |step, counts|
      step_type = step['type']
      counts[step_type] += 1 if step_type.present?
    end

    return nil if type_counts.empty?

    dots = type_counts.flat_map do |type, count|
      color = dot_colors[type] || 'bg-slate-400'
      label = dot_labels[type] || type&.titleize || 'Step'
      visible_count = [count, 2].min
      visible_count.times.map do
        content_tag(:span, '', class: "inline-block w-2 h-2 rounded-full #{color}", title: "#{label} (#{count})")
      end
    end

    safe_join(dots)
  end
end
