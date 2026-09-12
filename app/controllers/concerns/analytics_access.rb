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
end
