module Dashboard
  # What the CSR dashboard reads: the viewer's pins and their own runs. The
  # Editor and Admin home is Dashboard::Home; the org-wide stats this used to
  # carry for it were removed with that page (spec 2026-09-12).
  class DataLoader
    # Distinct workflows the user has run, ordered by most-recent run. Returns up
    # to 5 Scenarios (the most recent live Scenario per workflow), so views can
    # show status and a re-run action without extra queries. Bounded scan keeps
    # this portable across SQLite (test) and Postgres (prod).
    RECENTLY_RUN_LIMIT = 5
    RECENTLY_RUN_SCAN = 100

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

      counts = live_scenarios.where(workflow_id: ids).group(:workflow_id).count
      last_runs = live_scenarios.where(workflow_id: ids).group(:workflow_id).maximum(:created_at)
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

    private

    def user_scenarios
      @user_scenarios ||= Scenario.where(user: user)
    end

    def live_scenarios
      @live_scenarios ||= user_scenarios.where(purpose: "live")
    end
  end
end
