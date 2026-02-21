class SimulationsController < ApplicationController
  before_action :set_workflow, only: %i[new create]

  def show
    @simulation = current_user.simulations.find(params[:id])
    @workflow = @simulation.workflow
  end

  def new
    @simulation = Simulation.new
    @workflow = Workflow.find(params[:workflow_id])
    ensure_can_view_workflow!(@workflow)
  end

  def create
    @workflow = Workflow.find(params[:workflow_id])
    ensure_can_view_workflow!(@workflow)

    @simulation = Simulation.new(simulation_params)
    @simulation.workflow = @workflow
    @simulation.user = current_user
    @simulation.current_step_index = 0
    @simulation.execution_path = []
    @simulation.results = {}
    @simulation.inputs = {}

    if @simulation.save
      # Redirect to step view instead of executing immediately
      redirect_to step_simulation_path(@simulation), notice: "Simulation started."
    else
      render :new, status: :unprocessable_content
    end
  end

  def step
    @simulation = current_user.simulations.find(params[:id])
    @workflow = @simulation.workflow

    # Guard clauses for terminal/waiting states
    return if handle_step_guard_redirects

    # Handle navigation (back or jump-to-step)
    handle_back_navigation if params[:back].present?
    handle_jump_navigation if params[:step].present?

    # Auto-advance sub_flow steps immediately without user interaction
    return if auto_advance_non_interactive_step

    # NOTE: escalate and resolve steps show UI first, then process on Continue click
    # They are NOT auto-advanced here - they need user acknowledgment
  end

  def stop
    @simulation = current_user.simulations.find(params[:id])
    @workflow = @simulation.workflow

    # Stop the workflow
    @simulation.stop!(@simulation.current_step_index)
    redirect_to simulation_path(@simulation), notice: "Workflow stopped."
  end

  def next_step
    @simulation = current_user.simulations.find(params[:id])
    @workflow = @simulation.workflow

    # Prevent processing if stopped
    if @simulation.stopped?
      redirect_to simulation_path(@simulation), alert: "This workflow has been stopped and cannot be continued."
      return
    end

    # Get answer from params
    answer = params[:answer]

    # Process the current step
    # Note: checkpoint steps won't process here - they use resolve_checkpoint instead
    if @simulation.process_step(answer)
      # After processing a sub_flow step, parent may now be awaiting_subflow
      if @simulation.awaiting_subflow?
        active_child = @simulation.active_child_simulation
        if active_child
          redirect_to step_simulation_path(active_child)
        else
          redirect_to step_simulation_path(@simulation)
        end
        return
      end

      if @simulation.complete?
        # If this is a child simulation, redirect to parent's step view to resume it
        if @simulation.parent_simulation.present?
          redirect_to step_simulation_path(@simulation.parent_simulation)
        else
          redirect_to simulation_path(@simulation), notice: "Simulation completed successfully!"
        end
      else
        redirect_to step_simulation_path(@simulation)
      end
    else
      redirect_to step_simulation_path(@simulation), alert: "Failed to process step."
    end
  end

  private

  # Returns true if a redirect was issued (caller should return), false otherwise.
  def handle_step_guard_redirects
    if @simulation.stopped?
      redirect_to simulation_path(@simulation), notice: "This workflow has been stopped."
      return true
    end

    if @simulation.complete?
      if @simulation.parent_simulation.present?
        redirect_to step_simulation_path(@simulation.parent_simulation)
      else
        redirect_to simulation_path(@simulation), notice: "Simulation completed!"
      end
      return true
    end

    if @simulation.awaiting_subflow?
      handle_awaiting_subflow_redirect
      return true
    end

    false
  end

  def handle_awaiting_subflow_redirect
    active_child = @simulation.active_child_simulation
    if active_child && !active_child.complete?
      redirect_to step_simulation_path(active_child)
    else
      @simulation.process_subflow_completion
      if @simulation.complete?
        redirect_to simulation_path(@simulation), notice: "Simulation completed!"
      else
        redirect_to step_simulation_path(@simulation)
      end
    end
  end

  def handle_back_navigation
    return unless @simulation.execution_path.present? && @simulation.execution_path.length > 0

    popped_step = pop_to_interactive_step
    return unless popped_step

    rebuild_simulation_state_from_path
    restore_position_from_step(popped_step)
    @simulation.status = 'active' if @simulation.status == 'completed'
    @simulation.save
  end

  def pop_to_interactive_step
    while @simulation.execution_path.length > 0
      candidate = @simulation.execution_path.pop
      next if candidate['step_type'] == 'sub_flow'
      return candidate
    end
    nil
  end

  def rebuild_simulation_state_from_path
    @simulation.results = {}
    @simulation.inputs = {}
    @simulation.execution_path.each do |path_entry|
      next unless path_entry['answer'].present?

      if @simulation.graph_mode? && path_entry['step_uuid'].present?
        step = @workflow.find_step_by_id(path_entry['step_uuid'])
      elsif path_entry['step_index'].present?
        idx = path_entry['step_index'].to_i
        step = @workflow.steps[idx] if idx >= 0 && idx < @workflow.steps.length
      end

      next unless step && step['type'] == 'question'

      input_key = step['variable_name'].presence || (path_entry['step_index'] || 0).to_s
      @simulation.inputs[input_key] = path_entry['answer']
      @simulation.inputs[step['title']] = path_entry['answer']
      @simulation.results[step['title']] = path_entry['answer']
      @simulation.results[step['variable_name']] = path_entry['answer'] if step['variable_name'].present?
    end
  end

  def restore_position_from_step(popped_step)
    if @simulation.graph_mode? && popped_step['step_uuid'].present?
      @simulation.current_node_uuid = popped_step['step_uuid']
    elsif popped_step['step_index'].present?
      @simulation.current_step_index = popped_step['step_index'].to_i
    end
  end

  def handle_jump_navigation
    step_index = params[:step].to_i
    return unless step_index >= 0 && step_index < @simulation.execution_path.length

    path_item = @simulation.execution_path[step_index]
    return unless path_item && path_item['step_index'].present?

    target_step_index = path_item['step_index']
    @simulation.execution_path = @simulation.execution_path[0..step_index]

    # Rebuild results and inputs from execution path up to this point
    @simulation.results = {}
    @simulation.inputs = {}
    @simulation.execution_path.each do |path_entry|
      next unless path_entry['answer'].present?

      entry_step_index = path_entry['step_index'].to_i
      next unless entry_step_index >= 0 && entry_step_index < @workflow.steps.length

      step = @workflow.steps[entry_step_index]
      next unless step && step['type'] == 'question'

      input_key = step['variable_name'].presence || entry_step_index.to_s
      @simulation.inputs[input_key] = path_entry['answer']
      @simulation.inputs[step['title']] = path_entry['answer']
      @simulation.results[step['title']] = path_entry['answer']
      @simulation.results[step['variable_name']] = path_entry['answer'] if step['variable_name'].present?
    end

    next_step_index = target_step_index.to_i + 1
    if next_step_index >= @workflow.steps.length
      @simulation.status = 'completed'
      @simulation.current_step_index = @workflow.steps.length
    else
      @simulation.current_step_index = next_step_index
    end

    @simulation.save
  end

  # Returns true if a redirect was issued (caller should return), false otherwise.
  def auto_advance_non_interactive_step
    current_step = @simulation.current_step
    return false unless current_step && current_step['type'] == 'sub_flow'

    @simulation.process_step(nil)

    if @simulation.awaiting_subflow?
      active_child = @simulation.active_child_simulation
      redirect_to step_simulation_path(active_child || @simulation)
      return true
    end

    if @simulation.complete?
      redirect_to_completion(@simulation)
    else
      redirect_to step_simulation_path(@simulation)
    end
    true
  end

  # Redirect to the appropriate completion destination for a simulation.
  def redirect_to_completion(simulation, message: "Simulation completed!")
    if simulation.parent_simulation.present?
      redirect_to step_simulation_path(simulation.parent_simulation)
    else
      redirect_to simulation_path(simulation), notice: message
    end
  end

  def set_workflow
    # Handled in actions
  end

  def simulation_params
    # Permit workflow_id, inputs are optional (will be built up step by step)
    params.require(:simulation).permit(:workflow_id, inputs: {})
  end
end
