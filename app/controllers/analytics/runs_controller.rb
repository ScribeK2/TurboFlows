module Analytics
  # One call, read-only (spec 2026-09-12): what the agent chose at each step,
  # across sub-flows and handoffs. The results page's panels, without anything
  # that acts on the run or assumes the viewer can open its workflow.
  class RunsController < ApplicationController
    include AnalyticsAccess

    def show
      @scenario = Scenario.find_by(id: params[:id])
      return deny_analytics_access! unless analytics_scope.includes_run?(@scenario)

      # A call is read from its origin, as the results pages read it.
      origin = @scenario.run_origin
      return redirect_to(analytics_run_path(origin)) if origin != @scenario

      @workflow = @scenario.workflow
      @ending = @scenario.run_ending
      @agent = @scenario.user
      @agent_name = @agent ? @agent.display_label : "an anonymous visitor"
      @back_path = @agent ? analytics_agent_path(@agent) : analytics_path
      @back_label = @agent ? "Back to #{@agent_name}" : "Back to Analytics"
    end
  end
end
