# Shared helpers for the Scenario and Player runners.
#
# Options arrive either as hashes ({"label" => .., "value" => ..}) or as plain
# strings, depending on how the step was authored. Both runners open-coded the
# same normalization; it lives here now so they cannot drift again.
module RunnerHelper
  # How far a thread entry is indented, in levels.
  #
  # Capped: SubflowValidator allows nesting to depth 10, and the Player's layout
  # is tighter than the Scenario's with embed tighter still. Two levels is
  # enough to say "we are inside something"; past that the reader gets the fact
  # without the run walking off the right edge.
  THREAD_MAX_INDENT = 2

  def runner_thread_indent(entry)
    [entry["depth"].to_i, THREAD_MAX_INDENT].min
  end

  # The depth the open card sits at: how many sub-flows deep the run currently
  # is. Without it the card outdents while the run is still inside one, which
  # reads as the sub-flow having ended — the opposite of what indentation is
  # here to say.
  # One query per level, unlike ScenarioSettler.auto_processable? which was
  # changed to read parent_scenario_id precisely to avoid that. The id cannot
  # answer this one — depth is the length of the chain, not whether it exists —
  # and SubflowValidator caps nesting at 10, so this is a bounded walk once per
  # render rather than per advance. Batch it if a run ever nests deeply enough
  # to notice.
  def runner_thread_current_depth(scenario)
    depth = 0
    frame = scenario
    depth += 1 while (frame = frame.parent_scenario)
    [depth, THREAD_MAX_INDENT].min
  end

  # What a completed step says once it has collapsed into a row.
  #
  # Reads the entry and only the entry. Steps get edited and deleted after runs,
  # so a row built from the live Step record would replay a call with text
  # nobody ever saw, or fail outright on a uuid that no longer resolves. The
  # entry is the historical record; the Step is current state.
  #
  # nil when there is nothing honest to say — the row still shows its title, and
  # a blank beats an invented summary.
  def runner_row_summary(entry)
    case entry["step_type"]
    when "question" then entry["answer"].presence
    when "form"     then entry["response_summary"].presence
    when "action"   then "Done"
    when "message"  then "Read"
    when "escalate" then escalation_summary(entry)
    when "resolve"  then ["Resolved", entry["resolution_type"].presence].compact.join(" — ")
    end
  end

  # Messages the summary block still has to show, once the fields have taken the
  # ones that belong to them.
  #
  # A message shown under its own input must not also be shouted from the block
  # above; a message whose field is not on the page must not vanish with it. The
  # fallback is defensive — nothing in Steps::Form can name a field outside its
  # own options today — but the builder autosaves, so a step can be edited
  # between the render and the submit.
  #
  # A step with no field errors (Escalate, Resolve) keeps every message, which is
  # exactly what it did before any of this existed.
  def runner_unattached_errors(step, errors, field_errors)
    return Array(errors) if field_errors.blank?

    rendered = Array(step.try(:fields)).filter_map { |field| field["name"] }
    Array(errors) - field_errors.slice(*rendered).values.flatten
  end

  def runner_option_value(option)
    option.is_a?(Hash) ? (option["value"] || option["label"]) : option
  end

  def runner_option_label(option)
    option.is_a?(Hash) ? (option["label"] || option["value"]) : option
  end

  def runner_input_type(answer_type)
    case answer_type
    when "number" then "number"
    when "date" then "date"
    else "text"
    end
  end

  def runner_input_placeholder(answer_type)
    case answer_type
    when "number" then "Enter a number"
    when "date" then "YYYY-MM-DD"
    else "Type your answer..."
    end
  end

  # Older entries predate recording the target, so this degrades to the bare
  # fact rather than printing an em dash with nothing after it.
  def escalation_summary(entry)
    target = entry["target_type"].presence
    return "Escalated" unless target

    ["Escalated to #{target}", entry["priority"].presence].compact.join(" — ")
  end

  # Priority and resolution keep their pills: both mark an exceptional state,
  # which is what UIGUIDE reserves a pill for.
  def runner_priority_badge_class(priority)
    case priority
    when "urgent", "critical" then "badge--alert"
    when "high" then "badge--warning"
    else ""
    end
  end

  def runner_resolution_badge_class(resolution_type)
    case resolution_type
    when "success" then "badge--resolve"
    when "failure" then "badge--alert"
    when "transfer", "ticket" then "badge--info"
    when "manager_escalation" then "badge--warning"
    else ""
    end
  end

  # Whether selecting an answer submits the step on its own.
  #
  # Single source of truth, because it drives two things that MUST agree: the
  # scenario-step controller's auto-advance value (set on the shell) and whether
  # a Continue button renders (decided in the partial). When they disagreed, a
  # question with options but an answer_type outside yes_no/multiple_choice
  # rendered radio cards with no Continue and no auto-submit — a dead end the
  # run could not leave.
  #
  # The rule mirrors the render branches: auto-advance exactly when the answer
  # is a set of radio cards. Dropdowns and free-text keep their Continue button.
  def runner_auto_advances?(step)
    answer_type = step.try(:answer_type)
    return true if answer_type == "yes_no"

    answer_type != "dropdown" && step.try(:options).present?
  end
end
