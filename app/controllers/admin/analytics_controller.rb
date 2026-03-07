require "csv"

class Admin::AnalyticsController < ApplicationController
  before_action :ensure_admin!

  def index
    @date_range = parse_date_range
    @base_scope = build_base_scope

    # Stat cards
    @total_runs = @base_scope.count
    @completed_count = @base_scope.where(outcome: %w[completed resolved escalated]).count
    @completion_rate = @total_runs > 0 ? (@completed_count.to_f / @total_runs * 100).round(1) : 0
    @avg_duration = @base_scope.where.not(duration_seconds: nil).average(:duration_seconds)&.round || 0
    @escalated_count = @base_scope.where(outcome: "escalated").count
    @escalation_rate = @total_runs > 0 ? (@escalated_count.to_f / @total_runs * 100).round(1) : 0

    # Overview tab
    @outcome_breakdown = @base_scope.group(:outcome).count
    @runs_over_time = build_runs_over_time

    # Workflows tab
    @workflow_stats = build_workflow_stats

    # Agents tab
    @agent_stats = build_agent_stats

    # Operations tab
    @dropoff_points = build_dropoff_points
    @busiest_hours = @base_scope.where.not(started_at: nil)
                       .group("strftime('%H', started_at)")
                       .count
                       .sort_by { |hour, _| hour.to_i }

    # Filter dropdown data
    @workflows_for_filter = Workflow.joins(:scenarios).distinct.order(:title)
    @users_for_filter = User.joins(:scenarios).distinct.order(:email)
    @groups_for_filter = Group.order(:name)

    respond_to do |format|
      format.html
      format.csv { send_csv_export }
    end
  end

  private

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
    if params[:group_id].present?
      workflow_ids = GroupWorkflow.where(group_id: params[:group_id]).select(:workflow_id)
      scope = scope.where(workflow_id: workflow_ids)
    end
    scope
  end

  def build_runs_over_time
    scope = @base_scope.where.not(started_at: nil)
    @runs_grouped_by_week = @date_range.nil? || (@date_range.last - @date_range.first) > 30.days
    if @runs_grouped_by_week
      scope.group("strftime('%Y-%W', started_at)").count
    else
      scope.group("date(started_at)").count
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
        "SUM(CASE WHEN scenarios.outcome IN ('completed','resolved','escalated') THEN 1 ELSE 0 END) as completed_count",
        "AVG(scenarios.duration_seconds) as avg_duration",
        "SUM(CASE WHEN scenarios.outcome = 'escalated' THEN 1 ELSE 0 END) as escalated_count",
        "MAX(scenarios.started_at) as last_run"
      )
      .order("total_runs DESC")
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
        "SUM(CASE WHEN scenarios.outcome IN ('completed','resolved') THEN 1 ELSE 0 END) as completed_count",
        "SUM(CASE WHEN scenarios.outcome = 'escalated' THEN 1 ELSE 0 END) as escalated_count",
        "AVG(scenarios.duration_seconds) as avg_duration",
        "MAX(scenarios.started_at) as last_active"
      )
      .order("total_runs DESC")
  end

  def build_dropoff_points
    abandoned = @base_scope.where(outcome: "abandoned")
    dropoffs = Hash.new { |h, k| h[k] = { count: 0, workflow_title: "" } }

    abandoned.includes(:workflow).find_each do |scenario|
      next unless scenario.execution_path.present?

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
