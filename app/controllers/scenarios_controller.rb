class ScenariosController < ApplicationController
  include SubflowOrchestration

  before_action :ensure_can_manage_workflows!

  def show
    @scenario = current_user.scenarios.find(params[:id])
    @workflow = @scenario.workflow
  end

  def step
    @scenario = current_user.scenarios.find(params[:id])
    @workflow = @scenario.root_workflow

    # Guard clauses for terminal/waiting states
    return if handle_step_guard_redirects

    # Auto-advance sub_flow steps immediately without user interaction
    return if auto_advance_non_interactive_step

    # Record the moment this step is displayed for per-step timing
    @scenario.record_step_started

    # NOTE: escalate and resolve steps show UI first, then process on Continue click
    # They are NOT auto-advanced here - they need user acknowledgment
  end

  def back
    @scenario = current_user.scenarios.find(params[:id])
    ScenarioNavigator.new(@scenario).go_back
    redirect_to step_scenario_path(@scenario)
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

    # Prevent processing if stopped
    if @scenario.stopped?
      redirect_to scenario_path(@scenario), alert: "This workflow has been stopped and cannot be continued."
      return
    end

    # Record end time for the step the user is leaving
    @scenario.record_step_ended

    # Store escalation_reason/resolution_notes in scenario inputs for ScenarioStepProcessor
    @scenario.inputs ||= {}
    @scenario.inputs["escalation_reason"] = params[:escalation_reason] if params[:escalation_reason].present?
    @scenario.inputs["resolution_notes"] = params[:resolution_notes] if params[:resolution_notes].present?

    # Get answer from params
    answer = params[:answer]
    resolved_here = ActiveModel::Type::Boolean.new.cast(params[:resolved_here]) || false

    case @scenario.process_step(answer, resolved_here: resolved_here)
    in { status: :blocked, errors: }        then render_blocked_step(errors)
    in { status: :awaiting_subflow }        then redirect_to_subflow_if_awaiting?(@scenario)
    in { status: :resolved }                then handle_child_completion(@scenario)
    in { status: :advanced }                then redirect_to subflow_step_path(@scenario)
    else redirect_to step_scenario_path(@scenario), alert: "Failed to process step."
    end
  end

  private

  # Auto-advancing a step the user never saw. Blocked and halted both mean it
  # did not move, which is what the boolean used to say — the outcome is always
  # a truthy object, so this has to be asked explicitly now.
  #
  # Duplicated in PlayerController — the two shells share no seam yet.
  def auto_advance_failed?(outcome)
    outcome.blocked? || outcome.halted?
  end

  # A refused step re-renders where the user already is, with the reasons.
  # 422 because Turbo discards a 200 that is not a redirect.
  def render_blocked_step(errors)
    @step_errors = errors
    @submitted = submitted_form_values
    render :step, status: :unprocessable_content
  end

  # Values from the refused submit, so a blocked form keeps what was typed.
  # Duplicated in PlayerController — the two shells share no seam yet.
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
      handle_child_completion(@scenario)
      return true
    end

    if @scenario.awaiting_subflow?
      handle_awaiting_subflow(@scenario)
      return true
    end

    false
  end

  # SubflowOrchestration template methods
  def subflow_step_path(scenario)
    step_scenario_path(scenario)
  end

  def subflow_completion_path(scenario)
    scenario_path(scenario)
  end

  # Returns true if a redirect was issued (caller should return), false otherwise.
  def auto_advance_non_interactive_step
    current_step = @scenario.current_step
    return false unless current_step

    is_subflow_step = current_step.step_type == 'sub_flow'
    # Auto-process resolve steps in child scenarios so sub-flows complete seamlessly
    is_child_resolve = @scenario.parent_scenario.present? && current_step.step_type == 'resolve'

    return false unless is_subflow_step || is_child_resolve

    if auto_advance_failed?(@scenario.process_step(nil))
      @scenario.reload
      redirect_to step_scenario_path(@scenario)
      return true
    end

    return true if redirect_to_subflow_if_awaiting?(@scenario)

    if @scenario.complete?
      handle_child_completion(@scenario)
    else
      redirect_to subflow_step_path(@scenario)
    end
    true
  end

  # Redirect to the appropriate completion destination for a scenario.
  def redirect_to_completion(scenario, message: "Scenario completed!")
    if scenario.parent_scenario.present?
      redirect_to step_scenario_path(scenario.parent_scenario)
    else
      redirect_to scenario_path(scenario), notice: message
    end
  end

  def set_workflow
    # Handled in actions
  end
end
