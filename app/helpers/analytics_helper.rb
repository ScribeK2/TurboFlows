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
    "abandoned" => "analytics-bar--muted"
  }.freeze

  def analytics_outcome_label(outcome)
    analytics_in_progress?(outcome) ? "In progress" : outcome.capitalize
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

  private

  def analytics_in_progress?(outcome)
    outcome.blank? || outcome == ScenarioRollup::PENDING
  end
end
