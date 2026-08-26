# Shared helpers for the Scenario and Player runners.
#
# Options arrive either as hashes ({"label" => .., "value" => ..}) or as plain
# strings, depending on how the step was authored. Both runners open-coded the
# same normalization; it lives here now so they cannot drift again.
module RunnerHelper
  # Whether this deployment renders the run as a growing thread rather than one
  # card at a time. See config/initializers/stacked_runner.rb, which carries the
  # removal condition.
  #
  # Read through the config every time rather than memoized, so a test or a
  # console can flip it.
  def stacked_runner?
    Rails.configuration.x.stacked_runner.present?
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

  # The answered steps of the whole run, oldest first.
  #
  # Reads from the root scenario so a sub-flow shows the steps that led into it
  # rather than restarting at one. flattened_execution_path splices each child
  # scenario's own path in at the point its sub-flow began, which is what makes
  # a single uninterrupted list possible.
  def runner_trail_entries(scenario)
    flattened_execution_path(scenario.root_scenario)
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
