class ScenariosController < ApplicationController
  include RunnerShell

  before_action :ensure_can_manage_workflows!
  before_action :set_scenario

  # next_step, back, stop and show are RunnerShell's.

  # A pure read. It renders the run; it never moves it.
  #
  # This used to auto-process sub_flow steps and resume finished sub-flows, so a
  # GET mutated state — which is how Turbo's hover prefetch was able to drive
  # the runner, and why two tabs on one run raced each other. Moving is POST
  # work now, done by ScenarioSettler.
  def step
    elsewhere = runner_step_redirect(@scenario)
    return redirect_to(elsewhere) if elsewhere

    assign_runner_step_state(@scenario)
  end

  private

  # A simulation is its author's: nobody else's run is reachable here.
  def set_scenario
    @scenario = current_user.scenarios.find(params[:id])
  end

  # RunnerShell template methods
  def runner_step_path(scenario) = step_scenario_path(scenario)
  def runner_results_path(scenario) = scenario_path(scenario)
  def runner_next_path(scenario) = next_step_scenario_path(scenario)
  def runner_stop_path(scenario) = stop_scenario_path(scenario)
  def runner_back_path(scenario) = back_scenario_path(scenario)
  def runner_shows_cancel? = true
end
