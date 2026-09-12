module Analytics
  # One agent's calls, newest first (spec 2026-09-12). Reached from the Agents
  # tab, and from an administrator's user page. A call is counted as the
  # headline counts it, so a call handed across workflows is one row.
  class AgentsController < ApplicationController
    include AnalyticsAccess

    PER_PAGE = 25

    def show
      @agent = User.find_by(id: params[:id])
      return deny_analytics_access! unless analytics_scope.includes_agent?(@agent)

      @range = analytics_current_range
      @purpose = params[:purpose].presence_in(%w[live simulation])

      calls = CallStatistics.new(agent_runs).calls.sort_by { |call| [call.started_at.to_i, call.origin_id] }.reverse
      @total_calls = calls.size
      @total_pages = [(@total_calls / PER_PAGE.to_f).ceil, 1].max
      @page = params[:page].to_i.clamp(1, @total_pages)
      @calls = calls.slice((@page - 1) * PER_PAGE, PER_PAGE) || []

      @ending_workflows = Scenario.where(id: @calls.map(&:ending_id)).pluck(:id, :workflow_id).to_h
      @workflow_titles = Workflow.where(id: @calls.map(&:workflow_id) + @ending_workflows.values)
                                 .pluck(:id, :title).to_h
    end

    private

    # "all" is every run still held; the rollups behind the page's All time
    # cannot list calls.
    def agent_runs
      scope = analytics_scope.scenarios.where(user: @agent)
      scope = scope.where(started_at: analytics_date_range) unless @range == "all"
      scope = scope.where(purpose: @purpose) if @purpose
      scope
    end
  end
end
