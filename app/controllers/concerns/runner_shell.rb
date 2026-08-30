# frozen_string_literal: true

# The run, for both runner shells. What is left in ScenariosController and
# PlayerController is the part that is genuinely different: their URLs, their
# layouts, and who is allowed in.
#
# Each shell supplies the two URLs its runner lives at; everything else — where
# a GET belongs, which step is open, how far an answer moves the run, whether it
# crossed a sub-flow boundary, whether it finished — is decided here and by
# ScenarioSettler, and is the same for both.
#
# This replaces SubflowOrchestration, whose job was to redirect around sub-flow
# boundaries after each outcome. The settler crosses those boundaries itself and
# reports where the run came to rest, so there is nothing left to orchestrate:
# the answer is always "stream the run to wherever it landed".
#
# It was called RunnerAdvance while it owned only the POST. The GET half stayed
# written twice and drifted — five decisions about the same run had two answers
# depending on which URL the agent was at — so the name stopped describing the
# seam before the seam was finished. See RunnerShellParityTest for the five.
module RunnerShell
  extend ActiveSupport::Concern

  private

  # Template methods — each including controller MUST define both.
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

  # Where a GET on the runner belongs, or nil if it belongs right here.
  #
  # Every branch answers the same question — which run is this, the one the
  # agent started or the sub-flow frame they are standing in — and answers it
  # the way both #stop actions already do: the run they started.
  def runner_step_redirect(scenario)
    # A stopped frame is a stopped tree: Scenario#stop! cascades to the root and
    # every unfinished descendant. So the frame has no outcome of its own to
    # show, and its results are the root's.
    return runner_results_path(scenario.root_scenario) if scenario.stopped?

    # A finished *child* is a finished sub-flow, not a finished run. Sending the
    # agent to the root's results would show a summary for a run still in
    # progress; the parent's step page is where they belong, and it offers
    # Resume because a parent whose child has finished is parked.
    #
    # A finished *root* run gets no redirect at all: its ending stays on the
    # transcript and results are offered as a link, rather than the page being
    # replaced by a card that throws away what the agent was reading.
    return runner_step_path(scenario.parent_scenario) if scenario.complete? && scenario.parent_scenario

    # A run waiting on a child that is still going belongs at the child's URL.
    # A redirect writes nothing, so this keeps the action pure; the case where
    # the child has *finished* needs a POST, and #parked? surfaces that as a
    # Resume control instead of healing it here.
    active_child = scenario.awaiting_subflow? ? scenario.active_child_scenario : nil
    runner_step_path(active_child) if active_child && !active_child.complete?
  end

  # What a shell needs to render the run, computed once so the two cannot
  # disagree about which step is open.
  #
  # They did disagree. The Player read its own step off current_node_uuid with a
  # fallback to the workflow's first step, and never asked whether the run had
  # finished — so a completed run rendered an answerable card whose only
  # possible reply was "This run has already finished."
  def assign_runner_step_state(scenario)
    @scenario = scenario
    # The header names the run the agent started, not the sub-flow frame. This
    # is what respond_to_settled already does, so reading the frame here meant
    # the title changed on answer and changed back on reload.
    @workflow = scenario.root_workflow
    @parked = scenario.parked?
    @open_step = scenario.complete? || @parked ? nil : scenario.current_step
    scenario.record_step_started
  end

  # The answer the user gave, read the same way by both shells.
  #
  # These were parsed per-controller and had already drifted: the shared button
  # bar submits `resolved_here`, the Scenario runner read that, and the Player
  # read `resolved` — a name nothing submits. Its "Resolved" button therefore
  # advanced the run instead of ending it, silently. Reading inputs is part of
  # the seam, not something each shell gets its own opinion about.
  # A form submits `answer` as a nested hash; every other step submits a scalar.
  #
  # Converted here, because what arrives is ActionController::Parameters and
  # that is **not** a Hash — `is_a?(Hash)` is false for it since Rails 5. The
  # processor guards with exactly that check and so threw every form response
  # away, failing every required field no matter what the agent typed: a form
  # step with any required field could not be submitted at all. Reading the
  # submission is part of the seam, which is why the conversion lives here and
  # not in either shell.
  def runner_answer
    raw = params[:answer] || params[:selected_option]
    raw.is_a?(ActionController::Parameters) ? raw.permit!.to_h : raw
  end

  def runner_resolved_here?
    ActiveModel::Type::Boolean.new.cast(params[:resolved_here]).present?
  end

  # Values from the refused submit, so a blocked form keeps what was typed.
  # Both shells carried this verbatim; reading the submission is part of the
  # seam, not something each shell gets its own copy of.
  def submitted_form_values
    values = runner_answer
    values.is_a?(Hash) ? values : {}
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
    thread_before = helpers.runner_thread_entries(scenario).length

    # Reading the answer and stamping the step that is ending are part of
    # advancing, not something each shell does first in its own order — they
    # had already drifted into opposite orders. A terminal run skips both: the
    # settler still decides (it returns the halt below), this only stops a
    # refusal from restamping the last step of a run that is over.
    unless scenario.terminal?
      stash_runner_inputs(scenario)
      scenario.record_step_ended
    end

    settled = ScenarioSettler.new(scenario).settle(answer, resolved_here: resolved_here)

    respond_to_settled(settled, thread_before)
  end

  # Rewinding, answered the same way as an answer: without a redirect, so the
  # page the agent is reading stays put.
  def rewind_runner(scenario)
    ScenarioNavigator.new(scenario).go_back

    @scenario = scenario
    @workflow = scenario.root_workflow
    @open_step = scenario.complete? || scenario.parked? ? nil : scenario.current_step
    render :back, formats: [:turbo_stream]
  end

  # The runner answers the POST rather than redirecting away from it, which is
  # what keeps the page — and the transcript on it — in place.
  def respond_to_settled(settled, thread_before)
    @scenario = settled.scenario
    @workflow = @scenario.root_workflow

    if settled.blocked?
      # A refusal is not a new step: nothing collapses, nothing appends, and the
      # run has not moved. The card is re-rendered in place with the reasons —
      # which also rebuilds the form, clearing the submit guard and the spinner
      # that sit outside the errors node.
      @step_errors = settled.outcome.errors
      @field_errors = settled.outcome.field_errors
      @submitted = submitted_form_values
      @thread_tail = []
      @open_step = @scenario.current_step
      render :advance, formats: [:turbo_stream], status: :unprocessable_content
      return
    end

    # A halt is not a refusal and not a move: the run could not act on this
    # answer at all. It has to be said out loud, or a stale tab or a lost
    # optimistic-locking race drops the agent's answer in silence.
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
