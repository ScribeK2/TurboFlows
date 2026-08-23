# Shared helpers for the Scenario and Player runners.
#
# Options arrive either as hashes ({"label" => .., "value" => ..}) or as plain
# strings, depending on how the step was authored. Both runners open-coded the
# same normalization; it lives here now so they cannot drift again.
module RunnerHelper
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
end
