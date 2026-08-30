# Per-step timing for the Scenario model.
# Stamps started_at/ended_at/duration_seconds on execution_path entries as the
# runner moves through a run.
module ScenarioExecution
  extend ActiveSupport::Concern

  # Record the moment a step is displayed to the user.
  # The timestamp is stored as a pending attr_accessor and consumed by build_path_entry.
  def record_step_started
    self.step_started_at_pending = Time.current.iso8601(3)
  end

  # Record the moment a user advances past the current step.
  # Stamps ended_at and duration_seconds on the last execution_path entry.
  def record_step_ended
    return if execution_path.blank?

    last_entry = execution_path.last
    return unless last_entry && last_entry["started_at"].present?

    now = Time.current
    last_entry["ended_at"] = now.iso8601(3)
    started = Time.zone.parse(last_entry["started_at"])
    last_entry["duration_seconds"] = (now - started).round(1)
    begin
      save!(touch: false)
    rescue ActiveRecord::StaleObjectError
      Rails.logger.warn "[Scenario ##{id}] Stale object on record_step_ended — timing data lost (non-critical)"
    end
  end
end
