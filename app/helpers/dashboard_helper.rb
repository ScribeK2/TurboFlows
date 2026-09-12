module DashboardHelper
  # Time-of-day greeting in the user's own time zone.
  # Falls back to the app default zone if the user's TZ is blank or unrecognized.
  def time_based_greeting(user)
    zone = ActiveSupport::TimeZone[user&.time_zone.to_s] || Time.zone
    hour = Time.use_zone(zone) { Time.current.hour }

    case hour
    when 5..11  then "Good morning"
    when 12..16 then "Good afternoon"
    when 17..21 then "Good evening"
    else             "Working late"
    end
  end

  # First word of display_name, falling back to the email local-part.
  def greeting_name(user)
    return "" if user.blank?

    user.display_name.to_s.split.first.presence || user.email.to_s.split("@").first
  end

  # Today's date formatted in the user's time zone (e.g., "Tuesday, April 28").
  def greeting_date(user)
    zone = ActiveSupport::TimeZone[user&.time_zone.to_s] || Time.zone
    Time.use_zone(zone) { Time.current.strftime("%A, %B %-d") }
  end

  # One sentence naming each kind of problem Admin::Attention found, for the home
  # page's admin strip. The same readers as the Admin Overview, so they agree.
  def attention_summary(attention)
    kinds = []
    if attention.awaiting_groups_count.positive?
      kinds << "#{pluralize(attention.awaiting_groups_count, 'user')} waiting for a group"
    end
    if attention.no_audience_count.positive?
      kinds << "#{pluralize(attention.no_audience_count, 'published workflow')} with no audience"
    end
    kinds << "email is not set up" if attention.email_unconfigured?
    kinds << "background jobs are not running" if attention.worker_down?
    kinds << pluralize(attention.failed_jobs_count, "failed job") if attention.failed_jobs_count.positive?
    kinds << "nightly jobs have stalled" if attention.stalled_task_keys.any?
    kinds.to_sentence.upcase_first
  end
end
