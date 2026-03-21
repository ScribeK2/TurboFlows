module ScenariosHelper
  def scenario_back_button(scenario)
    return nil unless scenario.execution_path.present? && scenario.execution_path.length > 0

    link_to step_scenario_path(scenario, back: true),
            class: "scenario-btn-cancel" do
      raw('<svg class="icon icon--sm" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"></path></svg>') + "Back"
    end
  end

  # Returns "Step X" for the user's current position.
  # For child scenarios, sums all ancestor execution path lengths + own path length + 1.
  # Walks the full parent chain to support deeply nested sub-flows.
  def scenario_step_counter(scenario, workflow)
    total = (scenario.execution_path&.length || 0) + 1
    ancestor = scenario.parent_scenario
    while ancestor.present?
      total += (ancestor.execution_path&.length || 0)
      ancestor = ancestor.parent_scenario
    end
    "Step #{total}"
  end

  # Returns the inner content for a stepper pill: green checkmark for completed,
  # number badge for current/future, with a small step type icon.
  def scenario_stepper_step_content(path_item, index, is_completed, is_current)
    step_type = path_item['step_type'] || path_item['type']
    type_icon = step_type.present? ? step_type_svg_icon(step_type, css_classes: "icon icon--xs inline flex-shrink-0") : ""

    if is_completed
      checkmark = tag.svg(
        tag.path(d: "M5 13l4 4L19 7", 'stroke-linecap': "round", 'stroke-linejoin': "round", 'stroke-width': "2"),
        class: "icon icon--xs inline flex-shrink-0",
        fill: "none",
        stroke: "currentColor",
        viewBox: "0 0 24 24",
        xmlns: "http://www.w3.org/2000/svg"
      )
      safe_join([checkmark, type_icon, tag.span(index + 1, class: "font-semibold")])
    else
      safe_join([type_icon, tag.span(index + 1, class: "font-semibold")])
    end
  end

  # CSS classes for the step number badge based on step type.
  STEP_NUMBER_CLASSES = {
    'question' => 'badge badge--question',
    'action' => 'badge badge--action',
    'message' => 'badge badge--message',
    'sub_flow' => 'badge badge--sub-flow',
    'escalate' => 'badge badge--escalate',
    'resolve' => 'badge badge--resolve'
  }.freeze

  def scenario_step_number_classes(step_type)
    STEP_NUMBER_CLASSES[step_type] || 'badge'
  end

  # CSS classes for a stepper pill based on its state and step type.
  STEPPER_TYPE_CLASSES = {
    'question' => 'stepper-pill--question',
    'action' => 'stepper-pill--action',
    'message' => 'stepper-pill--message',
    'sub_flow' => 'stepper-pill--sub-flow',
    'escalate' => 'stepper-pill--escalate',
    'resolve' => 'stepper-pill--resolve'
  }.freeze

  def scenario_stepper_classes(is_completed, is_current, step_type = nil)
    base = "stepper-pill"

    if is_current
      "#{base} stepper-pill--current"
    elsif is_completed
      modifier = STEPPER_TYPE_CLASSES[step_type] || 'stepper-pill--completed'
      "#{base} #{modifier}"
    else
      "#{base} stepper-pill--pending"
    end
  end

  # Generates a dynamic summary sentence for completed scenarios.
  # E.g. "Completed 8 steps in 2m 14s -- 4 questions answered, 2 routing decisions -- resolved as Success"
  def scenario_summary_sentence(scenario)
    parts = []
    path = scenario.execution_path || []
    step_count = path.length

    # Duration
    duration_seconds = scenario.duration_seconds.to_i
    duration_text = if duration_seconds < 60
                      "#{duration_seconds}s"
                    elsif duration_seconds < 3600
                      "#{duration_seconds / 60}m #{duration_seconds % 60}s"
                    else
                      "#{duration_seconds / 3600}h #{(duration_seconds % 3600) / 60}m"
                    end

    parts << "Completed #{step_count} #{'step'.pluralize(step_count)} in #{duration_text}"

    # Counts by step type
    type_counts = path.each_with_object(Hash.new(0)) { |item, counts| counts[item['step_type']] += 1 }
    type_parts = []
    type_parts << "#{type_counts['question']} #{'question'.pluralize(type_counts['question'])} answered" if type_counts['question'] > 0
    type_parts << "#{type_counts['action']} #{'action'.pluralize(type_counts['action'])} performed" if type_counts['action'] > 0
    parts << type_parts.join(", ") if type_parts.any?

    # Resolution/escalation info
    results = scenario.results || {}
    if results['_resolution'].present?
      resolution_type = results['_resolution']['type']&.titleize
      parts << "resolved as #{resolution_type}" if resolution_type.present?
    elsif results['_escalation'].present?
      escalation_type = results['_escalation']['type']&.titleize
      parts << "escalated to #{escalation_type}" if escalation_type.present?
    end

    parts.join(" — ")
  end

  # Humanizes raw result keys: strips step_ prefix, replaces underscores, titleizes.
  # E.g. "step_6_outlook_success_check" -> "Outlook Success Check"
  def format_result_key(key)
    formatted = key.to_s
    formatted = formatted.sub(/\Astep_\d+_/, '')
    formatted = formatted.tr('_', ' ')
    formatted.titleize
  end

  # Groups regular results into categorized subsections for display.
  # Returns an array of { label: String, results: Hash } hashes, skipping empty groups.
  def categorize_scenario_results(scenario)
    results = (scenario.results || {}).reject { |k, _| k.to_s.start_with?('_') }
    return [] if results.empty?

    input_keys = (scenario.inputs || {}).keys.map(&:to_s)

    user_inputs = results.select { |k, _| input_keys.include?(k.to_s) }
    outcomes = results.reject { |k, _| input_keys.include?(k.to_s) }

    groups = []
    groups << { label: "User Inputs", results: user_inputs } if user_inputs.any?
    groups << { label: "Outcomes", results: outcomes } if outcomes.any?
    groups
  end
end
