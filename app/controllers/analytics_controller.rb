require "csv"

class AnalyticsController < ApplicationController
  include AnalyticsAccess

  # Two modes, and deliberately no stitching between them.
  #
  # Within retention the page reads raw runs and every filter works. "All time"
  # reads the rollup tables instead, which reach back past the horizon but
  # cannot answer per-agent, per-step or per-hour questions — those need the
  # individual rows. Blending the two would produce a page whose numbers are
  # right for some ranges and quietly partial for others, which is the failure
  # this whole change exists to remove. So the mode is explicit and the page
  # says what it cannot show.
  def index
    @rollup_mode = params[:range] == "all"
    return render_from_rollups if @rollup_mode

    @date_range = parse_date_range
    @base_scope = build_base_scope

    # Stat cards and the Overview count calls (ISSUE-003): a call handed through
    # three workflows is one call, not three runs, and lasts from where it
    # started to where it ended. Rates are over calls that have ended (spec
    # Q67, Q71): a call still going has not failed to complete. The Workflows
    # and Agents tabs still count each workflow's own runs.
    calls = CallStatistics.new(@base_scope)
    @total_calls = calls.total
    @finished_calls = calls.finished
    @completed_count = calls.completed
    @completion_rate = percentage(@completed_count, @finished_calls)
    @avg_duration = calls.average_duration_seconds
    @escalated_count = calls.escalated
    @escalation_rate = percentage(@escalated_count, @finished_calls)

    # Overview tab
    @outcome_breakdown = calls.outcome_breakdown
    @runs_grouped_by_week = @date_range.nil? || (@date_range.last - @date_range.first) > 30.days
    @calls_over_time = calls.over_time(weekly: @runs_grouped_by_week)

    # Workflows tab
    @workflow_stats = build_workflow_stats
    # Last Run and Last Active come from maximum, which casts by the column's
    # type. A MAX in the stats select came back from SQLite as a String, which
    # time_ago_in_words read in the server's zone: hours off anywhere but UTC.
    @last_runs = @base_scope.group(:workflow_id).maximum(:started_at)

    # Agents tab
    @agent_stats = build_agent_stats
    @last_active = @base_scope.group(:user_id).maximum(:started_at)

    # Step Performance tab
    @step_performance = build_step_performance(@base_scope)

    # Operations tab
    @dropoff_points = build_dropoff_points
    @busiest_hours = @base_scope.where.not(started_at: nil)
                                .group(hour_extract_sql)
                                .count
                                .sort_by { |hour, _| hour.to_i }

    # Filter dropdown data (deduplicate workflows with same title, keeping highest id)
    @workflows_for_filter = Workflow.joins(:scenarios).distinct.order(:title)
                                    .select(:id, :title)
                                    .group_by(&:title)
                                    .map { |_title, wfs| wfs.max_by(&:id) }
    @users_for_filter = User.joins(:scenarios).distinct.order(:email)
    @groups_for_filter = Group.tree_nodes

    if @step_performance_capped || @dropoff_capped
      flash.now[:notice] = "Analytics showing most recent 5,000 scenarios. Export CSV for full dataset."
    end

    respond_to do |format|
      format.html
      format.csv { send_csv_export }
    end
  end

  private

  # The all-time view. Same ivars, same shapes, different source — so the
  # partials do not need to know which mode they are in, except where a panel
  # genuinely has no rollup behind it.
  def render_from_rollups
    scope = ScenarioRollup.all
    dropoffs = ScenarioDropoffRollup.all
    @rollup_earliest_day = ScenarioRollup.minimum(:day)

    # Calls, as in every other range. Days rolled up before calls were counted
    # carry none, so the page says from when they are.
    totals = scope.group(:outcome).sum(:calls_count).select { |_outcome, count| count.positive? }
    @total_calls = totals.values.sum
    @finished_calls = @total_calls - totals.fetch(ScenarioRollup::PENDING, 0)
    @completed_count = totals.slice(*Scenario::COMPLETED_OUTCOMES).values.sum
    @escalated_count = totals.fetch("escalated", 0)
    @completion_rate = percentage(@completed_count, @finished_calls)
    @escalation_rate = percentage(@escalated_count, @finished_calls)
    @avg_duration = scope.average_call_duration_seconds
    @outcome_breakdown = totals
    @calls_counted_from = scope.where(calls_count: 1..).minimum(:day)

    @runs_grouped_by_week = true
    @calls_over_time = scope.group(:day).sum(:calls_count)
                            .transform_keys { |d| d.to_date.beginning_of_week }
                            .each_with_object(Hash.new(0)) { |(week, n), acc| acc[week] += n }
                            .sort.to_h

    @workflow_stats = rollup_workflow_stats
    # A Date: a rollup knows the day a workflow last ran, not the time.
    @last_runs = scope.group(:workflow_id).maximum(:day)
    @dropoff_points = rollup_dropoff_points(dropoffs)

    # No rollup can reconstruct these: they are read from individual runs.
    # Named here so the partials can say so rather than rendering an empty
    # table that looks like "no activity".
    @agent_stats = nil
    @step_performance = nil
    @busiest_hours = nil

    @workflows_for_filter = []
    @users_for_filter = []
    @groups_for_filter = []

    respond_to do |format|
      format.html { render :index }
      format.csv do
        redirect_to analytics_path(range: "90d"),
                    alert: "CSV export lists individual runs, which the all-time view does not hold. " \
                           "Exported the last 90 days instead."
      end
    end
  end

  def percentage(part, total)
    total.positive? ? (part.to_f / total * 100).round(1) : 0
  end

  def rollup_workflow_stats
    ScenarioRollup
      .joins(:workflow)
      .group("workflows.id", "workflows.title")
      .select(
        "workflows.id as workflow_id",
        "workflows.title as workflow_title",
        "SUM(scenario_rollups.runs_count) as total_runs",
        "SUM(CASE WHEN scenario_rollups.outcome <> 'pending' " \
        "THEN scenario_rollups.runs_count ELSE 0 END) as finished_runs",
        # In step with Scenario::COMPLETED_OUTCOMES; literal so nothing is interpolated.
        "SUM(CASE WHEN scenario_rollups.outcome IN ('completed','resolved','escalated','transferred') " \
        "THEN scenario_rollups.runs_count ELSE 0 END) as completed_count",
        "CASE WHEN SUM(scenario_rollups.duration_count) > 0 " \
        "THEN SUM(scenario_rollups.duration_sum_seconds) * 1.0 / SUM(scenario_rollups.duration_count) " \
        "ELSE NULL END as avg_duration",
        "SUM(CASE WHEN scenario_rollups.outcome = 'escalated' " \
        "THEN scenario_rollups.runs_count ELSE 0 END) as escalated_count"
      )
      .order(Arel.sql("total_runs DESC"))
  end

  def rollup_dropoff_points(scope)
    totals = scope.joins(:workflow)
                  .group("workflows.id", "workflows.title", :step_title)
                  .sum(:runs_count)
    points = totals.map do |(workflow_id, workflow_title, step_title), count|
      { count: count, step_title: step_title,
        workflow_title: workflow_title, workflow_id: workflow_id }
    end
    points.sort_by { |d| -d[:count] }.first(20)
  end

  # "all" means every run STILL HELD, not all time — runs are deleted at the
  # retention horizon, so this cannot reach further back than they are kept.
  # The filter UI says so. The durable fix is rolling runs up before deleting
  # them, so trend history outlives the transcripts; until that exists, nothing
  # here should imply a longer history than the database holds.
  def parse_date_range
    case params[:range]
    when "7d"  then 7.days.ago..Time.current
    when "90d" then 90.days.ago..Time.current
    when "all" then nil
    else 30.days.ago..Time.current # default 30d
    end
  end

  def build_base_scope
    scope = Scenario.all
    scope = scope.where(started_at: @date_range) if @date_range
    scope = scope.where(purpose: params[:purpose]) if params[:purpose].present? && params[:purpose] != "all"
    scope = scope.where(workflow_id: params[:workflow_id]) if params[:workflow_id].present?
    scope = scope.where(user_id: params[:user_id]) if params[:user_id].present?
    # A department's figures include its teams (spec Q37): the group and every
    # subgroup, the same reach membership gives.
    if params[:group_id].present?
      group_ids = [params[:group_id].to_i, *Group.descendant_ids_for([params[:group_id]])]
      workflow_ids = GroupWorkflow.where(group_id: group_ids).select(:workflow_id)
      scope = scope.where(workflow_id: workflow_ids)
    end
    scope
  end

  def sqlite?
    ActiveRecord::Base.connection.adapter_name.downcase.include?("sqlite")
  end

  def hour_extract_sql
    if sqlite?
      "strftime('%H', started_at)"
    else
      "to_char(started_at, 'HH24')"
    end
  end

  def build_workflow_stats
    @base_scope
      .joins(:workflow)
      .group("workflows.id", "workflows.title")
      .select(
        "workflows.id as workflow_id",
        "workflows.title as workflow_title",
        "COUNT(*) as total_runs",
        "SUM(CASE WHEN scenarios.outcome IS NOT NULL THEN 1 ELSE 0 END) as finished_runs",
        # In step with Scenario::COMPLETED_OUTCOMES; literal so nothing is interpolated.
        "SUM(CASE WHEN scenarios.outcome IN ('completed','resolved','escalated','transferred') " \
        "THEN 1 ELSE 0 END) as completed_count",
        "AVG(scenarios.duration_seconds) as avg_duration",
        "SUM(CASE WHEN scenarios.outcome = 'escalated' THEN 1 ELSE 0 END) as escalated_count"
      )
      .order(total_runs: :desc)
  end

  def build_agent_stats
    @base_scope
      .joins(:user)
      .group("users.id", "users.email", "users.display_name")
      .select(
        "users.id as user_id",
        "users.email as user_email",
        "users.display_name as user_display_name",
        "COUNT(*) as total_runs",
        # In step with Scenario::COMPLETED_OUTCOMES; literal so nothing is interpolated.
        "SUM(CASE WHEN scenarios.outcome IN ('completed','resolved','escalated','transferred') " \
        "THEN 1 ELSE 0 END) as completed_count",
        "SUM(CASE WHEN scenarios.outcome = 'escalated' THEN 1 ELSE 0 END) as escalated_count",
        "AVG(scenarios.duration_seconds) as avg_duration"
      )
      .order(total_runs: :desc)
  end

  # Performance note: This iterates matching scenarios in Ruby to parse
  # JSON execution_path data. Capped at 5,000 to prevent memory/time issues.
  #
  # Future optimization: denormalize step timing data into a dedicated
  # step_executions table (step_id, scenario_id, duration_seconds, started_at)
  # and query with SQL aggregation instead.
  def build_step_performance(scenarios)
    step_times = Hash.new { |h, k| h[k] = [] }

    scope = scenarios.where.not(execution_path: nil)
    @step_performance_capped = scope.count > 5000

    scope.order(:id).limit(5000).each do |scenario|
      Array(scenario.execution_path).each do |entry|
        next if entry["duration_seconds"].blank?

        key = entry["step_title"] || "Unknown"
        step_times[key] << entry["duration_seconds"].to_f
      end
    end

    results = step_times.map do |title, durations|
      {
        title: title,
        count: durations.size,
        avg_duration: (durations.sum / durations.size).round(1),
        max_duration: durations.max.round(1),
        min_duration: durations.min.round(1)
      }
    end
    results.sort_by { |s| -s[:avg_duration] }
  end

  def build_dropoff_points
    # Drop-off asks where AGENTS bail out on a live call. `build_base_scope`
    # filters purpose only when the param is present, so this counted every
    # purpose — mixing editors abandoning half-built test runs in the builder
    # with real agent behaviour, at whatever ratio the team happened to test.
    #
    # That was harmless while nothing produced abandoned runs except an
    # explicit Cancel. The idle sweep now settles them at real volume, and
    # simulations are the pool least likely to ever be finished, so the noise
    # would have swamped the signal. An explicit purpose (including "all")
    # still wins; this only supplies the default.
    abandoned = @base_scope.where(outcome: "abandoned")
    abandoned = abandoned.where(purpose: "live") if params[:purpose].blank?
    @dropoff_capped = abandoned.count > 5000
    dropoffs = Hash.new { |h, k| h[k] = { count: 0, workflow_title: "" } }

    abandoned.includes(:workflow).order(:id).limit(5000).each do |scenario|
      next if scenario.execution_path.blank?

      last_step = scenario.execution_path.last
      next unless last_step

      key = "#{scenario.workflow_id}:#{last_step['step_title']}"
      dropoffs[key][:count] += 1
      dropoffs[key][:step_title] = last_step["step_title"]
      dropoffs[key][:workflow_title] = scenario.workflow&.title
      dropoffs[key][:workflow_id] = scenario.workflow_id
    end

    dropoffs.values.sort_by { |d| -d[:count] }.first(20)
  end

  def send_csv_export
    csv_data = CSV.generate(headers: true) do |csv|
      csv << ["ID", "Workflow", "User", "Purpose", "Outcome", "Started At", "Completed At", "Duration (s)", "Status"]
      @base_scope.includes(:workflow, :user).find_each do |scenario|
        csv << [
          scenario.id,
          scenario.workflow&.title,
          scenario.user&.email,
          scenario.purpose,
          scenario.outcome,
          scenario.started_at&.iso8601,
          scenario.completed_at&.iso8601,
          scenario.duration_seconds,
          scenario.status
        ]
      end
    end

    send_data csv_data,
              filename: "analytics-#{Date.current}.csv",
              type: "text/csv; charset=utf-8",
              disposition: "attachment"
  end
end
