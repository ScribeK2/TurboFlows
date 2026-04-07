class ScenariosController < ApplicationController
  before_action :ensure_can_manage_workflows!
  before_action :set_workflow, only: %i[new create]

  def show
    @scenario = current_user.scenarios.find(params[:id])
    @workflow = @scenario.workflow
  end

  def new
    @scenario = Scenario.new
    @workflow = Workflow.find(params[:workflow_id])
    ensure_can_view_workflow!(@workflow)
  end

  def create
    @workflow = Workflow.find(params[:workflow_id])
    ensure_can_view_workflow!(@workflow)

    @scenario = Scenario.new(scenario_params)
    @scenario.workflow = @workflow
    @scenario.user = current_user
    @scenario.current_step_index = 0
    @scenario.current_node_uuid = @workflow.start_node&.uuid
    @scenario.execution_path = []
    @scenario.results = {}
    @scenario.inputs = {}

    if @scenario.save
      # Redirect to step view instead of executing immediately
      redirect_to step_scenario_path(@scenario), notice: "Scenario started."
    else
      render :new, status: :unprocessable_content
    end
  end

  def step
    @scenario = current_user.scenarios.find(params[:id])
    @workflow = @scenario.root_workflow

    # Guard clauses for terminal/waiting states
    return if handle_step_guard_redirects

    # Handle navigation (back or jump-to-step)
    handle_back_navigation if params[:back].present?
    handle_jump_navigation if params[:step].present?

    # Auto-advance sub_flow steps immediately without user interaction
    return if auto_advance_non_interactive_step

    # Record the moment this step is displayed for per-step timing
    @scenario.record_step_started

    # NOTE: escalate and resolve steps show UI first, then process on Continue click
    # They are NOT auto-advanced here - they need user acknowledgment
  end

  def stop
    @scenario = current_user.scenarios.find(params[:id])
    @workflow = @scenario.workflow

    # Stop the workflow
    @scenario.stop!(@scenario.current_step_index)
    redirect_to scenario_path(@scenario), notice: "Workflow stopped."
  end

  def next_step
    @scenario = current_user.scenarios.find(params[:id])
    @workflow = @scenario.workflow

    # Prevent processing if stopped
    if @scenario.stopped?
      redirect_to scenario_path(@scenario), alert: "This workflow has been stopped and cannot be continued."
      return
    end

    # Record end time for the step the user is leaving
    @scenario.record_step_ended

    # Get answer from params
    answer = params[:answer]
    resolved_here = ActiveModel::Type::Boolean.new.cast(params[:resolved_here]) || false

    # Process the current step
    # Note: checkpoint steps won't process here - they use resolve_checkpoint instead
    if @scenario.process_step(answer, resolved_here: resolved_here)
      # After processing a sub_flow step, parent may now be awaiting_subflow
      if @scenario.awaiting_subflow?
        active_child = @scenario.active_child_scenario
        if active_child
          redirect_to step_scenario_path(active_child)
        else
          redirect_to step_scenario_path(@scenario)
        end
        return
      end

      if @scenario.complete?
        redirect_after_child_completion(@scenario)
      else
        redirect_to step_scenario_path(@scenario)
      end
    else
      redirect_to step_scenario_path(@scenario), alert: "Failed to process step."
    end
  end

  private

  # Returns true if a redirect was issued (caller should return), false otherwise.
  def handle_step_guard_redirects
    if @scenario.stopped?
      redirect_to scenario_path(@scenario), notice: "This workflow has been stopped."
      return true
    end

    if @scenario.complete?
      redirect_after_child_completion(@scenario)
      return true
    end

    if @scenario.awaiting_subflow?
      handle_awaiting_subflow_redirect
      return true
    end

    false
  end

  def handle_awaiting_subflow_redirect
    active_child = @scenario.active_child_scenario
    if active_child && !active_child.complete?
      redirect_to step_scenario_path(active_child)
    else
      @scenario.process_subflow_completion
      if @scenario.complete?
        redirect_to scenario_path(@scenario), notice: "Scenario completed!"
      else
        redirect_to step_scenario_path(@scenario)
      end
    end
  end

  def handle_back_navigation
    ScenarioNavigator.new(@scenario, @workflow).go_back
  end

  def handle_jump_navigation
    step_index = params[:step].to_i
    return unless step_index >= 0 && step_index < @scenario.execution_path.length

    path_item = @scenario.execution_path[step_index]
    return unless path_item && path_item['step_index'].present?

    target_step_index = path_item['step_index']
    @scenario.execution_path = @scenario.execution_path[0..step_index]

    # Rebuild results and inputs from execution path up to this point
    ordered_steps = @workflow.steps.order(:position).to_a
    @scenario.results = {}
    @scenario.inputs = {}
    @scenario.execution_path.each do |path_entry|
      next unless path_entry['answer'].present?

      entry_step_index = path_entry['step_index'].to_i
      next unless entry_step_index >= 0 && entry_step_index < ordered_steps.size

      step = ordered_steps[entry_step_index]
      next unless step.is_a?(Steps::Question)

      input_key = step.variable_name.presence || entry_step_index.to_s
      @scenario.inputs[input_key] = path_entry['answer']
      @scenario.inputs[step.title] = path_entry['answer']
      @scenario.results[step.title] = path_entry['answer']
      @scenario.results[step.variable_name] = path_entry['answer'] if step.variable_name.present?
    end

    next_step_index = target_step_index.to_i + 1
    total_steps = @workflow.steps.size
    if next_step_index >= total_steps
      @scenario.status = 'completed'
      @scenario.current_step_index = total_steps
    else
      @scenario.current_step_index = next_step_index
    end

    @scenario.save
  end

  # Returns true if a redirect was issued (caller should return), false otherwise.
  def auto_advance_non_interactive_step
    current_step = @scenario.current_step
    return false unless current_step

    is_subflow_step = current_step.step_type == 'sub_flow'
    # Auto-process resolve steps in child scenarios so sub-flows complete seamlessly
    is_child_resolve = @scenario.parent_scenario.present? && current_step.step_type == 'resolve'

    return false unless is_subflow_step || is_child_resolve

    @scenario.process_step(nil)

    if @scenario.awaiting_subflow?
      active_child = @scenario.active_child_scenario
      redirect_to step_scenario_path(active_child || @scenario)
      return true
    end

    if @scenario.complete?
      redirect_after_child_completion(@scenario)
    else
      redirect_to step_scenario_path(@scenario)
    end
    true
  end

  # Process completion of a scenario that may be a child sub-flow.
  # If child: completes parent sub-flow and redirects to parent's next step.
  # If root: redirects to results page.
  def redirect_after_child_completion(scenario)
    if scenario.parent_scenario.present?
      parent = scenario.parent_scenario
      parent.process_subflow_completion
      if parent.complete?
        redirect_to_completion(parent)
      else
        redirect_to step_scenario_path(parent)
      end
    else
      redirect_to_completion(scenario)
    end
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

  def scenario_params
    # Permit workflow_id, inputs are optional (will be built up step by step)
    params.require(:scenario).permit(:workflow_id, inputs: {})
  end
end
