module Dashboard
  # What the CSR home reads: a call to pick back up, the viewer's pins, and the
  # workflows they recently started (spec 2026-09-13). The Editor and Admin home
  # is Dashboard::Home.
  class DataLoader
    # Distinct workflows the user has run, ordered by most-recent run. Returns up
    # to 5 Scenarios (the most recent live Scenario per workflow), so views can
    # show status and a re-run action without extra queries. Bounded scan keeps
    # this portable across SQLite (test) and Postgres (prod).
    RECENTLY_RUN_LIMIT = 5
    RECENTLY_RUN_SCAN = 100

    # A workflow the viewer recently started, and how that call ended. The
    # ending comes from CallStatistics, which picks it in SQL the way
    # Scenario#run_ending does, so five rows cost the same as one.
    RecentRun = Data.define(:origin, :call) do
      delegate :workflow, to: :origin
      delegate :finished?, :outcome, to: :call
    end

    attr_reader :user

    def initialize(user)
      @user = user
    end

    def csr?
      !user.can_create_workflows?
    end

    def recent_scenarios
      @recent_scenarios ||= user_scenarios.includes(:workflow)
                                          .order(created_at: :desc)
                                          .limit(5)
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

    def recently_run_workflows
      @recently_run_workflows ||= begin
        seen = {}
        live_scenarios.includes(workflow: :tags)
                      .order(created_at: :desc)
                      .limit(RECENTLY_RUN_SCAN)
                      .each do |sc|
          next if sc.workflow.nil? || seen.key?(sc.workflow_id)

          seen[sc.workflow_id] = sc
          break if seen.size >= RECENTLY_RUN_LIMIT
        end
        seen.values
      end
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

    private

    def user_scenarios
      @user_scenarios ||= Scenario.where(user: user)
    end

    def live_scenarios
      @live_scenarios ||= user_scenarios.where(purpose: "live")
    end

    # Bounded scan, as recently_run_workflows had: portable across SQLite and
    # Postgres without DISTINCT ON.
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
