# frozen_string_literal: true

# Turning "the user answered" into a response, for both runner shells.
#
# Each shell supplies the two URLs its runner lives at; everything else — how
# far the run moves, whether it crossed a sub-flow boundary, whether it finished
# — is decided by ScenarioSettler and is the same for both.
#
# This replaces SubflowOrchestration, whose job was to redirect around sub-flow
# boundaries after each outcome. The settler crosses those boundaries itself and
# reports where the run came to rest, so there is nothing left to orchestrate:
# the answer is always "redirect to wherever it landed".
module RunnerAdvance
  extend ActiveSupport::Concern

  private

  # Template methods — each including controller MUST define these.
  #
  # Named for what they are rather than for sub-flows. The old pair was called
  # subflow_step_path / subflow_completion_path even though every caller used
  # them for ordinary steps too, which reads as though sub-flows are still a
  # special case in the runner. They are not.

  def runner_step_path(scenario)
    raise NotImplementedError, "#{self.class} must implement #runner_step_path"
  end

  def runner_results_path(scenario)
    raise NotImplementedError, "#{self.class} must implement #runner_results_path"
  end

  # A refused step re-renders where the user already is, with the reasons.
  def render_blocked_step(errors)
    raise NotImplementedError, "#{self.class} must implement #render_blocked_step"
  end

  def advance_runner(scenario, answer, resolved_here: false)
    respond_to_settled(ScenarioSettler.new(scenario).settle(answer, resolved_here: resolved_here))
  end

  def respond_to_settled(settled)
    scenario = settled.scenario

    if settled.blocked?
      render_blocked_step(settled.outcome.errors)
    elsif scenario.complete?
      redirect_to runner_results_path(scenario)
    else
      redirect_to runner_step_path(scenario)
    end
  end
end
