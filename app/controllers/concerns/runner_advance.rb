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

  # The answer the user gave, read the same way by both shells.
  #
  # These were parsed per-controller and had already drifted: the shared button
  # bar submits `resolved_here`, the Scenario runner read that, and the Player
  # read `resolved` — a name nothing submits. Its "Resolved" button therefore
  # advanced the run instead of ending it, silently. Reading inputs is part of
  # the seam, not something each shell gets its own opinion about.
  def runner_answer
    params[:answer] || params[:selected_option]
  end

  def runner_resolved_here?
    ActiveModel::Type::Boolean.new.cast(params[:resolved_here]).present?
  end

  # Escalation reason and resolution notes reach the processor through inputs.
  def stash_runner_inputs(scenario)
    scenario.inputs ||= {}
    scenario.inputs["escalation_reason"] = params[:escalation_reason] if params[:escalation_reason].present?
    scenario.inputs["resolution_notes"] = params[:resolution_notes] if params[:resolution_notes].present?
  end

  def advance_runner(scenario, answer, resolved_here: false)
    # How much thread already exists, so the stream can send only what this
    # answer added. Counted through the same traversal the thread renders from,
    # so the tail is tagged and depthed by construction rather than by the
    # controller trying to reproduce it.
    thread_before = stacked_runner? ? helpers.runner_thread_entries(scenario).length : 0

    settled = ScenarioSettler.new(scenario).settle(answer, resolved_here: resolved_here)

    if stacked_runner?
      respond_to_stacked(settled, thread_before)
    else
      respond_to_settled(settled)
    end
  end

  # Rewinding, answered the same way as an answer: without a redirect, so the
  # page the agent is reading stays put.
  def rewind_runner(scenario)
    ScenarioNavigator.new(scenario).go_back

    unless stacked_runner?
      redirect_to runner_step_path(scenario)
      return
    end

    @scenario = scenario
    @workflow = scenario.root_workflow
    @open_step = scenario.complete? || scenario.parked? ? nil : scenario.current_step
    render :back, formats: [:turbo_stream]
  end

  # Stacked answers the POST rather than redirecting away from it, which is what
  # keeps the page — and the transcript on it — in place.
  def respond_to_stacked(settled, thread_before)
    @scenario = settled.scenario
    @workflow = @scenario.root_workflow

    if settled.blocked?
      # A refusal is not a new step: nothing collapses, nothing appends, and the
      # run has not moved. The card is re-rendered in place with the reasons —
      # which also rebuilds the form, clearing the submit guard and the spinner
      # that sit outside the errors node.
      @step_errors = settled.outcome.errors
      @submitted = submitted_form_values
      @thread_tail = []
      @open_step = @scenario.current_step
      render :advance, formats: [:turbo_stream], status: :unprocessable_content
      return
    end

    # A halt is not a refusal and not a move: the run could not act on this
    # answer at all. Classic says so; streaming has to as well, or a stale tab
    # or a lost optimistic-locking race drops the agent's answer in silence.
    # Nothing appends — the empty tail is what keeps a second open card off the
    # page when the idempotency guard fires.
    if settled.halted?
      flash.now[:alert] = halted_message(settled.outcome.reason)
      @thread_tail = []
      @open_step = @scenario.complete? || @scenario.parked? ? nil : @scenario.current_step
      render :advance, formats: [:turbo_stream]
      return
    end

    @thread_tail = helpers.runner_thread_entries(@scenario).drop(thread_before)
    @open_step = @scenario.complete? || @scenario.parked? ? nil : @scenario.current_step
    render :advance, formats: [:turbo_stream]
  end

  def respond_to_settled(settled)
    scenario = settled.scenario

    if settled.blocked?
      # Classic only. This renders the controller's own @scenario, so a run
      # refused *after* settle descended into a child — a sub-flow opening on a
      # notes-required resolve — shows the parent and drops the errors. The old
      # code redirect-looped on the same input, so it is not a regression, and
      # the streamed path does not share it: that one renders settled.scenario.
      # This goes when classic goes.
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
