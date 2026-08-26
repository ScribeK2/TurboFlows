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

  included do
    # One definition of the flag, not two. The helper owns it; controllers ask
    # the helper. A switch defined in two places is a switch that eventually
    # disagrees with itself.
    delegate :stacked_runner?, to: :helpers
  end

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
      # NOTE: for the streamed response in a later PR: this renders the
      # controller's own @scenario. If a run is ever refused *after* settle
      # descended into a child — a sub-flow opening on a notes-required resolve
      # — that is the parent, and the errors go nowhere. The old code
      # redirect-looped on the same input, so this is not a regression, but the
      # stream rebuild is the moment to render settled.scenario instead.
      render_blocked_step(settled.outcome.errors)
    elsif settled.halted?
      redirect_to runner_step_path(scenario), alert: halted_message(settled.outcome.reason)
    elsif scenario.complete?
      redirect_to runner_results_path(scenario)
    else
      redirect_to runner_step_path(scenario)
    end
  end

  # A run that could not move, as opposed to one that was refused.
  #
  # :conflict is a lost optimistic-locking race — two tabs on the same run, or a
  # double submit. Saying nothing drops the user's answer silently, which is how
  # the old shells behaved for every halt except this one.
  def halted_message(reason)
    case reason
    when :conflict then "Someone else changed this run while you were answering. Your last answer was not saved."
    when :not_runnable then "This run has already finished."
    else "That step could not be processed."
    end
  end
end
