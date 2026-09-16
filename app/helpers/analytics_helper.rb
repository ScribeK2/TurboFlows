# How Analytics names and colours a run's outcome. A run with no outcome yet is
# still going (the live view's nil, the rollups' "pending") and says so, where
# it used to read "Unknown" (spec Q66).
module AnalyticsHelper
  OUTCOME_BARS = {
    "resolved" => "analytics-bar--resolved",
    "completed" => "analytics-bar--completed",
    "escalated" => "analytics-bar--escalated",
    "error" => "analytics-bar--error",
    "transferred" => "analytics-bar--transferred",
    "abandoned" => "analytics-bar--muted",
    # Stranded sits with abandoned rather than with error: nothing broke, the
    # workflow simply had no route for the answer it was given.
    "stranded" => "analytics-bar--muted"
  }.freeze

  # Outcomes whose column value does not read as English. Everything else is
  # capitalised, which is right for resolved/escalated/transferred and wrong for
  # "stranded" — that is a word about the run's shape, and the person reading
  # the table wants to know what the agent hit.
  OUTCOME_LABELS = {
    "stranded" => "No matching answer"
  }.freeze

  def analytics_outcome_label(outcome)
    return "In progress" if analytics_in_progress?(outcome)

    OUTCOME_LABELS.fetch(outcome) { outcome.capitalize }
  end

  def analytics_outcome_bar_class(outcome)
    return "analytics-bar--muted" if analytics_in_progress?(outcome)

    OUTCOME_BARS.fetch(outcome, "analytics-bar--default")
  end

  # When a workflow last ran or an agent was last active. A run carries a time; a
  # rollup knows only the day, and a day read as a time is hours since midnight,
  # so it reads in days. Days count in Time.zone, never through Date#to_time,
  # which is midnight in the server's own zone.
  def analytics_last_seen(value)
    return "Never" if value.nil?
    return "#{time_ago_in_words(value)} ago" unless value.is_a?(Date)

    case (Date.current - value).to_i
    when ..0 then "Today"
    when 1 then "Yesterday"
    else "#{distance_of_time_in_words(value.in_time_zone, Date.current.in_time_zone)} ago"
    end
  end

  # A duration as the Analytics tables write it: "4m 18s", or "42s" under a minute.
  def analytics_duration(seconds)
    seconds = seconds.to_i
    seconds >= 60 ? "#{seconds / 60}m #{seconds % 60}s" : "#{seconds}s"
  end

  private

  def analytics_in_progress?(outcome)
    outcome.blank? || outcome == ScenarioRollup::PENDING
  end
end
