class ScenariosController < ApplicationController
  include RunnerAdvance

  before_action :ensure_can_manage_workflows!

  def show
    @scenario = current_user.scenarios.find(params[:id])
    @workflow = @scenario.workflow
  end

  # A pure read. It renders the run; it never moves it.
  #
  # This used to auto-process sub_flow steps and resume finished sub-flows, so a
  # GET mutated state — which is how Turbo's hover prefetch was able to drive
  # the runner, and why two tabs on one run raced each other. Moving is POST
  # work now, done by ScenarioSettler.
  def step
    @scenario = current_user.scenarios.find(params[:id])
    @workflow = @scenario.root_workflow

    return if handle_step_guard_redirects

    @parked = @scenario.parked?
    @scenario.record_step_started
  end

  def back
    @scenario = current_user.scenarios.find(params[:id])
    rewind_runner(@scenario)
  end

  def stop
    @scenario = current_user.scenarios.find(params[:id])
    @workflow = @scenario.workflow

    # Stops the whole scenario tree, so report on the run the user actually
    # started rather than the sub-flow frame they happened to be inside.
    @scenario.stop!(@scenario.current_step_index)
    redirect_to scenario_path(@scenario.root_scenario), notice: "Workflow stopped."
  end

  def next_step
    @scenario = current_user.scenarios.find(params[:id])
    # root_workflow, matching #step: a blocked step re-renders this shell, and
    # the header names the run the user started, not the sub-flow frame.
    @workflow = @scenario.root_workflow

    if @scenario.stopped?
      redirect_to scenario_path(@scenario), alert: "This workflow has been stopped and cannot be continued."
      return
    end

    @scenario.record_step_ended
    stash_runner_inputs(@scenario)

    advance_runner(@scenario, runner_answer, resolved_here: runner_resolved_here?)
  end

  private

  # A refused step re-renders where the user already is, with the reasons.
  # 422 because Turbo discards a 200 that is not a redirect.
  def render_blocked_step(errors)
    @step_errors = errors
    @submitted = submitted_form_values
    render :step, status: :unprocessable_content
  end

  # Values from the refused submit, so a blocked form keeps what was typed.
  def submitted_form_values
    raw = params[:answer]
    raw.is_a?(ActionController::Parameters) ? raw.permit!.to_h : {}
  end

  # Returns true if a redirect was issued (caller should return), false otherwise.
  def handle_step_guard_redirects
    if @scenario.stopped?
      redirect_to scenario_path(@scenario), notice: "This workflow has been stopped."
      return true
    end

    if @scenario.complete?
      # A finished *child* is a finished sub-flow, not a finished run. Sending
      # the user to the root's results page would show a summary for a run still
      # in progress; the parent's step page is where they belong, and it offers
      # Resume because a parent whose child has finished is parked.
      if @scenario.parent_scenario
        redirect_to runner_step_path(@scenario.parent_scenario)
        return true
      end

      # A finished run: classic replaces the page with a "Run complete" card,
      # which throws away what the agent was reading. Stacked keeps the ending
      # on the transcript and offers results as a link.
      unless stacked_runner?
        redirect_to runner_results_path(@scenario)
        return true
      end
    end

    # A run waiting on a child that is still going belongs at the child's URL.
    # A redirect writes nothing, so this keeps the action pure; the case where
    # the child has *finished* needs a POST and is handled by #parked?.
    active_child = @scenario.awaiting_subflow? ? @scenario.active_child_scenario : nil
    if active_child && !active_child.complete?
      redirect_to runner_step_path(active_child)
      return true
    end

    false
  end

  # RunnerAdvance template methods
  def runner_step_path(scenario)
    step_scenario_path(scenario)
  end

  def runner_results_path(scenario)
    scenario_path(scenario)
  end
end
