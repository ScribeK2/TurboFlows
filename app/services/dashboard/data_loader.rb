module Dashboard
  class DataLoader
    attr_reader :user

    def initialize(user)
      @user = user
    end

    def csr?
      !user.can_create_workflows?
    end

    # -- Shared --

    def workflows
      @workflows ||= if user.can_create_workflows?
                       visible_ids = Workflow.visible_to(user).select(:id)
                       draft_ids = user.workflows.drafts.select(:id)
                       Workflow.where(id: visible_ids).or(Workflow.where(id: draft_ids))
                               .includes(:tags).order(created_at: :desc).limit(5)
                     else
                       Workflow.visible_to(user).includes(:tags).recent.limit(5)
                     end
    end

    def recent_scenarios
      @recent_scenarios ||= user_scenarios.includes(:workflow)
                                          .order(created_at: :desc)
                                          .limit(5)
    end

    # -- CSR-specific --

    def pinned_workflow_ids
      @pinned_workflow_ids ||= user.user_workflow_pins.pluck(:workflow_id).to_set
    end

    def pinned_workflows
      @pinned_workflows ||= user.pinned_workflows
                                .where(id: Workflow.visible_to(user).select(:id))
                                .includes(:tags, :steps)
                                .limit(UserWorkflowPin::MAX_PINS)
    end

    # Aggregate per-pinned-workflow run stats for the CSR launcher cards.
    # Returns { workflow_id => { runs:, last_run_at: } }, two queries total.
    def pinned_workflow_stats
      return @pinned_workflow_stats if defined?(@pinned_workflow_stats)

      ids = pinned_workflows.map(&:id)
      return (@pinned_workflow_stats = {}) if ids.empty?

      counts = live_scenarios.where(workflow_id: ids).group(:workflow_id).count
      last_runs = live_scenarios.where(workflow_id: ids).group(:workflow_id).maximum(:created_at)
      @pinned_workflow_stats = ids.index_with { |id| { runs: counts[id].to_i, last_run_at: last_runs[id] } }
    end

    # Distinct workflows the user has run, ordered by most-recent run.
    # Returns up to 5 Scenarios (the most recent live Scenario per workflow),
    # so views can show status and a re-run action without extra queries.
    # Bounded scan keeps this portable across SQLite (test) and Postgres (prod).
    RECENTLY_RUN_LIMIT = 5
    RECENTLY_RUN_SCAN = 100

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

    def scenarios_this_week
      @scenarios_this_week ||= live_scenarios
                               .where(created_at: Time.current.beginning_of_week..)
                               .count
    end

    def personal_scenario_total
      @personal_scenario_total ||= live_scenarios.count
    end

    def personal_completion_rate
      total = live_scenarios.count
      return 0 if total.zero?

      completed = live_scenarios.where(status: "completed").count
      ((completed * 100.0) / total).round
    end

    def most_used_workflow
      @most_used_workflow ||= begin
        result = live_scenarios.group(:workflow_id)
                               .order(Arel.sql("COUNT(*) DESC"))
                               .limit(1)
                               .pick(:workflow_id, Arel.sql("COUNT(*)"))
        if result&.first
          { workflow: Workflow.find_by(id: result.first), count: result.last }
        end
      end
    end

    # -- SME-specific (company-wide) --

    def workflow_count
      @workflow_count ||= Workflow.visible_to(user).count
    end

    def draft_count
      @draft_count ||= user.workflows.drafts.count
    end

    def company_scenario_total
      @company_scenario_total ||= Scenario.count
    end

    def company_completion_rate
      total = company_scenario_total
      return 0 if total.zero?

      completed = Scenario.where(status: "completed").count
      ((completed * 100.0) / total).round
    end

    def company_scenarios_this_week
      @company_scenarios_this_week ||= Scenario
                                       .where(created_at: Time.current.beginning_of_week..)
                                       .count
    end

    def scenario_active
      @scenario_active ||= user_scenarios.where(status: "active").count
    end

    # Number of the user's published workflows that currently have one or more
    # health-check errors. Drives the "needs attention" chip in the dashboard
    # header. Bounded to avoid scanning huge libraries on every dashboard load.
    HEALTH_CHECK_SCAN_LIMIT = 50

    def workflows_with_health_issues_count
      return 0 unless user.can_create_workflows?

      @workflows_with_health_issues_count ||= user.workflows
                                                  .published
                                                  .includes(steps: { transitions: :target_step })
                                                  .limit(HEALTH_CHECK_SCAN_LIMIT)
                                                  .count { |wf| WorkflowHealthCheck.call(wf).summary[:errors].positive? }
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
