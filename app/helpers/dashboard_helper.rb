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
end
