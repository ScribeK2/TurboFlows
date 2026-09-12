require "test_helper"

class AnalyticsHelperTest < ActionView::TestCase
  include AnalyticsHelper

  test "a run with no outcome yet is in progress, live or rolled up" do
    assert_equal "In progress", analytics_outcome_label(nil)
    assert_equal "In progress", analytics_outcome_label(ScenarioRollup::PENDING)
    assert_equal "Transferred", analytics_outcome_label("transferred")
  end

  test "each ending has its bar colour" do
    assert_equal "analytics-bar--resolved", analytics_outcome_bar_class("resolved")
    assert_equal "analytics-bar--transferred", analytics_outcome_bar_class("transferred")
    assert_equal "analytics-bar--muted", analytics_outcome_bar_class("abandoned")
    assert_equal "analytics-bar--muted", analytics_outcome_bar_class(nil)
    assert_equal "analytics-bar--muted", analytics_outcome_bar_class(ScenarioRollup::PENDING)
  end

  test "a run's time reads in minutes and hours, a rolled-up day in days" do
    assert_equal "Never", analytics_last_seen(nil)
    assert_equal "5 minutes ago", analytics_last_seen(5.minutes.ago)
    assert_equal "Today", analytics_last_seen(Date.current)
    assert_equal "Yesterday", analytics_last_seen(Date.current - 1)
    assert_equal "3 days ago", analytics_last_seen(Date.current - 3)
    assert_equal "about 1 year ago", analytics_last_seen(Date.current - 400)
  end

  test "a duration reads in minutes and seconds, or seconds under a minute" do
    assert_equal "42s", analytics_duration(42)
    assert_equal "1m 0s", analytics_duration(60)
    assert_equal "4m 18s", analytics_duration(258)
  end
end
