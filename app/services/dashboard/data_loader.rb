module Dashboard
  # What the CSR home reads: a call to pick back up, the viewer's pins, and the
  # workflows they recently started (spec 2026-09-13). The Editor and Admin home
  # is Dashboard::Home.
  class DataLoader
    # Recently Run: at most RECENTLY_RUN_LIMIT workflows, found in the newest
    # RECENTLY_RUN_SCAN calls the viewer started.
    RECENTLY_RUN_LIMIT = 5
    RECENTLY_RUN_SCAN = 100

    # A workflow the viewer recently started, and how that call ended. The
    # ending comes from CallStatistics, which picks it in SQL the way
    # Scenario#run_ending does, so five rows cost the same as one.
    RecentRun = Data.define(:origin, :call) do
      delegate :workflow, to: :origin
      delegate :finished?, :outcome, to: :call
    end

    # How recently a call must have been touched to be offered for resuming.
    # Closing the tab is how calls usually end, so most unfinished runs are
    # calls that are over; an hour covers a long hold without listing the day's
    # finished calls (spec Q10).
    RESUME_WINDOW = 60.minutes

    # The call home offers to pick back up. `frame` is what Resume opens: the
    # unfinished frame with the latest activity, which is the one the agent was
    # last on. `workflow` is where the call started.
    Resume = Data.define(:frame, :workflow, :step_title, :last_activity_at)

    # A frame's call, as Scenario#run_origin_id records it.
    CALL = Arel.sql("COALESCE(run_origin_id, id)")

    attr_reader :user

    def initialize(user)
      @user = user
    end

    def csr?
      !user.can_create_workflows?
    end

    def pinned_workflow_ids
      @pinned_workflow_ids ||= user.user_workflow_pins.pluck(:workflow_id).to_set
    end

    def pinned_workflows
      @pinned_workflows ||= user.pinned_workflows
                                .where(id: Workflow.visible_to(user).select(:id))
                                .includes(:tags, :steps)
                                .limit(UserWorkflowPin::MAX_PINS)
    end

    # Aggregate per-pinned-workflow run stats for the launcher rows.
    # Returns { workflow_id => { runs:, last_run_at: } }, two queries total.
    def pinned_workflow_stats
      return @pinned_workflow_stats if defined?(@pinned_workflow_stats)

      ids = pinned_workflows.map(&:id)
      return (@pinned_workflow_stats = {}) if ids.empty?

      counts = started_calls.where(workflow_id: ids).group(:workflow_id).count
      last_runs = started_calls.where(workflow_id: ids).group(:workflow_id).maximum(:created_at)
      @pinned_workflow_stats = ids.index_with { |id| { runs: counts[id].to_i, last_run_at: last_runs[id] } }
    end

    # Workflows the viewer started, one row per workflow for its latest call,
    # limited to workflows they can still run, so every Re-run works.
    def recently_run
      @recently_run ||= begin
        latest = latest_call_per_workflow
        calls = CallStatistics.new(Scenario.where(id: latest.map(&:id))).calls.index_by(&:origin_id)
        latest.map { |origin| RecentRun.new(origin:, call: calls.fetch(origin.id)) }
      end
    end

    # At most one: the viewer's call with the latest activity inside
    # RESUME_WINDOW that still has an unfinished frame. Activity is the whole
    # call's (Scenario#run_last_activity), because a parent parked on a live
    # sub-flow stopped its own clock when it parked. Every frame records its call
    # in run_origin_id, so this is two grouped queries rather than a run_frames
    # walk per call.
    def resume
      return @resume if defined?(@resume)

      @resume = build_resume
    end

    private

    def build_resume
      activity = live_scenarios.where(updated_at: RESUME_WINDOW.ago..).group(CALL).maximum(:updated_at)
      return if activity.empty?

      unfinished = live_scenarios.where.not(status: Scenario::TERMINAL_STATUSES)
                                 .where("COALESCE(run_origin_id, id) IN (?)", activity.keys)
                                 .to_a
      return if unfinished.empty?

      frame = unfinished.max_by { |f| [activity.fetch(f.run_origin_id || f.id), f.updated_at] }
      Resume.new(frame:, workflow: frame.run_origin.workflow, step_title: frame.current_step&.title,
                 last_activity_at: activity.fetch(frame.run_origin_id || frame.id))
    end

    def live_scenarios
      @live_scenarios ||= Scenario.where(user: user, purpose: "live")
    end

    # Bounded scan: portable across SQLite and Postgres without DISTINCT ON.
    def latest_call_per_workflow
      seen = {}
      started_calls.where(workflow_id: Workflow.visible_to(user).select(:id))
                   .includes(workflow: :tags)
                   .order(created_at: :desc)
                   .limit(RECENTLY_RUN_SCAN)
                   .each do |origin|
        next if seen.key?(origin.workflow_id)

        seen[origin.workflow_id] = origin
        break if seen.size >= RECENTLY_RUN_LIMIT
      end
      seen.values
    end

    def started_calls
      @started_calls ||= live_scenarios.origins
    end
  end
end
