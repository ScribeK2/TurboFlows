# Deliberately not an ApplicationController: ONCE polls /up before anyone has
# signed in, so the endpoint must not inherit Devise's authenticate filter or
# any other app-wide before_action. Reparenting this makes the health check
# redirect to the login page and the container read as permanently unhealthy.
class HealthController < ActionController::Base # rubocop:disable Rails/ApplicationController
  def show
    # Check 1: Primary database is writable
    ActiveRecord::Base.connection.execute("SELECT 1")

    # Check 2: solid_queue worker is alive (processed a job in last 5 minutes)
    if defined?(SolidQueue) && SolidQueue::Job.table_exists?
      last_finished = SolidQueue::Job.where.not(finished_at: nil).order(finished_at: :desc).pick(:finished_at)
      if last_finished.present? && last_finished < 5.minutes.ago
        render plain: "solid_queue stalled", status: :service_unavailable
        return
      end
    end

    render plain: "OK"
  end
end
