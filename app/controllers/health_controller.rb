class HealthController < ActionController::Base
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
