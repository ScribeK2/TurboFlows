# Analytics' one gate (spec 2026-09-12): administrators and group managers get
# in, and what each sees is AnalyticsScope's answer. Shared by the page and its
# drill-down so none of them decides access for itself.
module AnalyticsAccess
  extend ActiveSupport::Concern

  included do
    before_action :ensure_analytics_access!
  end

  private

  def analytics_scope
    @analytics_scope ||= AnalyticsScope.new(current_user)
  end

  def ensure_analytics_access!
    deny_analytics_access! unless analytics_scope.allowed?
  end

  # The same answer whether a record is out of scope or does not exist, so a
  # guessed id tells nobody anything.
  def deny_analytics_access!
    redirect_to root_path, alert: "You don't have permission to access this page."
  end

  # Managers read runs only; All time reads rollups, which cannot be limited to
  # a team, so it is offered to administrators alone.
  def analytics_ranges
    analytics_scope.all_time? ? %w[7d 30d 90d all] : %w[7d 30d 90d]
  end

  def analytics_current_range
    analytics_ranges.include?(params[:range]) ? params[:range] : "30d"
  end

  # The run window for a range. "all" is not a run window: the page reads
  # rollups for it, and the drill-down reads every run still held.
  def analytics_date_range
    case analytics_current_range
    when "7d" then 7.days.ago..Time.current
    when "90d" then 90.days.ago..Time.current
    else 30.days.ago..Time.current
    end
  end
end
