module ScenariosHelper
  # Back is a POST.
  #
  # It used to be a GET carrying ?back=true, which ScenariosController#step
  # acted on by rewinding and saving. Turbo 8 prefetches links on hover by
  # default and nothing here opts out, so hovering the control rewound the run —
  # twice, if the pointer passed over it twice, since go_back is not idempotent.
  #
  # Hidden entirely when the run cannot be rewound: see Scenario#can_go_back?.
  def scenario_back_button(scenario)
    return nil unless scenario.can_go_back?

    link_to back_scenario_path(scenario),
            class: "btn btn--plain",
            data: { turbo_method: :post } do
      back_icon = '<svg class="icon icon--sm" fill="none" stroke="currentColor" viewBox="0 0 24 24">' \
                  '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"></path></svg>'
      raw(back_icon) + "Back" # rubocop:disable Style/StringConcatenation -- SafeBuffer#+ preserves html_safe
    end
  end

  # Generates a dynamic summary sentence for completed scenarios.
  # E.g. "Completed 8 steps in 2m 14s -- 4 questions answered, 2 routing decisions -- resolved as Success"
  def scenario_summary_sentence(scenario)
    parts = []
    path = flattened_execution_path(scenario)
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
    type_parts << "#{type_counts['question']} #{'question'.pluralize(type_counts['question'])} answered" if type_counts['question'].positive?
    type_parts << "#{type_counts['action']} #{'action'.pluralize(type_counts['action'])} performed" if type_counts['action'].positive?
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

  # The steps of a run, with sub-flows spliced in where they happened.
  #
  # A flat audit list: the grouping marks the traversal emits are dropped, so
  # this reads exactly as it did before the thread existed.
  def flattened_execution_path(scenario)
    flatten_path_entries(scenario.execution_path || []).reject { |entry| entry["kind"] == "group_start" }
  end

  # The same traversal, keeping the structure: each entry tagged "step" or
  # "group_start" and carrying the depth it sits at.
  #
  # One walk, two readers. The results page wants the audit list above; the
  # runner thread wants to show where the call moved into a sub-flow and, by
  # outdenting again, where it came back. Sharing the traversal — recursive,
  # subtle, and already carrying a fix for a query per sub-flow — while
  # differing only at the call site is what stops the two drifting.
  #
  # Reads from the root, because a thread is the whole run: a sub-flow shows the
  # steps that led into it rather than restarting at one.
  def runner_thread_entries(scenario)
    flatten_path_entries(scenario.root_scenario.execution_path || [])
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

    user_inputs, outcomes = results.partition { |k, _| input_keys.include?(k.to_s) }.map(&:to_h)

    groups = []
    groups << { label: "User Inputs", results: user_inputs } if user_inputs.any?
    groups << { label: "Outcomes", results: outcomes } if outcomes.any?
    groups
  end

  private

  # Tagged "kind", not "type": entries already use "type" as a legacy fallback
  # for step_type, and a second meaning on the same key is how a reader ends up
  # treating a grouping mark as a step.
  def flatten_path_entries(path, depth = 0)
    flat = []
    # One query per nesting level rather than one per sub-flow entry. The runner
    # renders this on every step now, not just the results page, so a run with
    # several sub-flows was issuing a query each per page view.
    children = child_scenarios_for(path)

    path.each do |entry|
      if entry["subflow_started"].present? && entry["child_scenario_id"].present?
        # Emitted even when the child is gone. The mark is a fact about the call
        # — it went into another script — and saying so with the title the entry
        # already carries beats silence.
        flat << entry.merge("kind" => "group_start", "depth" => depth)

        child = children[entry["child_scenario_id"]]
        next unless child

        child_path = child.execution_path || []
        if child_path.any?
          last_entry = child_path.last
          last_type = last_entry["step_type"] || last_entry["type"]
          # The child's own terminal is the sub-flow ending, not the run ending;
          # the next card already implies it.
          child_path = child_path[0..-2] if %w[resolve escalate].include?(last_type)
        end
        flat.concat(flatten_path_entries(child_path, depth + 1))
      else
        flat << entry.merge("kind" => "step", "depth" => depth)
      end
    end

    flat
  end

  def child_scenarios_for(path)
    ids = path.filter_map do |entry|
      entry["child_scenario_id"] if entry["subflow_started"].present?
    end
    return {} if ids.empty?

    Scenario.where(id: ids).index_by(&:id)
  end
end
