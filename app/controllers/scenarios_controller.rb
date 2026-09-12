class ScenariosController < ApplicationController
  include RunnerShell

  before_action :ensure_can_manage_workflows!

  # A run's results live at its origin. Any other frame — a sub-flow, or the
  # workflow a handoff moved the run to — sends the reader there, so an old link
  # or a dashboard row cannot show one workflow's slice of the call as the call.
  def show
    @scenario = current_user.scenarios.find(params[:id])
    origin = @scenario.run_origin
    return redirect_to(scenario_path(origin)) if origin != @scenario

    @workflow = @scenario.workflow
    @ending = @scenario.run_ending
  end

  # A pure read. It renders the run; it never moves it.
  #
  # This used to auto-process sub_flow steps and resume finished sub-flows, so a
  # GET mutated state — which is how Turbo's hover prefetch was able to drive
  # the runner, and why two tabs on one run raced each other. Moving is POST
  # work now, done by ScenarioSettler.
  def step
    @scenario = current_user.scenarios.find(params[:id])

    elsewhere = runner_step_redirect(@scenario)
    return redirect_to(elsewhere) if elsewhere

    assign_runner_step_state(@scenario)
  end

  def back
    @scenario = current_user.scenarios.find(params[:id])
    rewind_runner(@scenario)
  end

  def stop
    @scenario = current_user.scenarios.find(params[:id])
    @workflow = @scenario.workflow

    # Stops the whole scenario tree, so report on the run the user actually
    # started rather than the frame they happened to be inside. `run_origin`, not
    # `root_scenario`: after a handoff the frame is its own root.
    @scenario.stop!(@scenario.current_step_index)
    redirect_to runner_results_path(@scenario.run_origin), notice: "Workflow stopped."
  end

  # A stopped run gets no guard here. The settler halts it with :not_runnable
  # and the shell says so in place, which keeps the transcript the agent is
  # reading on screen — the same answer the Player gives. The redirect that used
  # to live here was the only place in the runner that navigated away from an
  # answer.
  def next_step
    @scenario = current_user.scenarios.find(params[:id])

    advance_runner(@scenario, runner_answer, resolved_here: runner_resolved_here?)
  end

  private

  # RunnerShell template methods
  def runner_step_path(scenario)
    step_scenario_path(scenario)
  end

  def runner_results_path(scenario)
    scenario_path(scenario)
  end
end
