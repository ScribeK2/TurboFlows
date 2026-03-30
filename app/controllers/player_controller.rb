class PlayerController < ApplicationController
  layout "player"

  before_action :authenticate_user!, except: %i[show_shared step next_step back show]
  before_action :set_scenario, only: %i[step next_step back show]

  def index
    @workflows = Workflow.published
                         .where(id: Workflow.visible_to(current_user).select(:id))
                         .includes(:tags, :versions)
                         .order(updated_at: :desc)
  end

  def start
    workflow = Workflow.published.find(params[:id])
    unless workflow.can_be_viewed_by?(current_user)
      redirect_to play_path, alert: "You don't have access to this workflow."
      return
    end

    scenario = Scenario.create!(
      workflow: workflow,
      user: current_user,
      purpose: "live",
      started_at: Time.current,
      current_step_index: 0,
      current_node_uuid: workflow.start_node&.uuid,
      execution_path: [],
      results: {},
      inputs: {}
    )
    redirect_to player_scenario_step_path(scenario)
  end

  def step
    @workflow = @scenario.workflow
    @current_step = resolve_current_step

    if @scenario.completed? || @scenario.stopped?
      redirect_to player_scenario_show_path(@scenario)
      return
    end

    # Handle awaiting_subflow: redirect to the active child scenario
    if @scenario.awaiting_subflow?
      active_child = @scenario.active_child_scenario
      if active_child && !active_child.complete?
        redirect_to player_scenario_step_path(active_child)
      else
        @scenario.process_subflow_completion
        redirect_to @scenario.complete? ? player_scenario_show_path(@scenario) : player_scenario_step_path(@scenario)
      end
      return
    end

    # Auto-advance sub_flow steps (they don't need user interaction)
    if @current_step&.step_type == "sub_flow"
      @scenario.process_step(nil)
      if @scenario.awaiting_subflow?
        active_child = @scenario.active_child_scenario
        redirect_to player_scenario_step_path(active_child || @scenario)
      elsif @scenario.complete?
        redirect_to player_scenario_show_path(@scenario)
      else
        redirect_to player_scenario_step_path(@scenario)
      end
      return
    end

    # Auto-advance resolve steps in child scenarios (so sub-flows complete seamlessly)
    if @scenario.parent_scenario.present? && @current_step&.step_type == "resolve"
      @scenario.process_step(nil)
      if @scenario.complete?
        parent = @scenario.parent_scenario
        parent.process_subflow_completion
        redirect_to parent.complete? ? player_scenario_show_path(parent) : player_scenario_step_path(parent)
      else
        redirect_to player_scenario_step_path(@scenario)
      end
      return
    end

    @scenario.step_started_at_pending = Time.current.iso8601(3)
  end

  def next_step
    answer = params[:answer] || params[:selected_option]
    @scenario.record_step_ended
    @scenario.process_step(answer, resolved_here: params[:resolved].present?)

    # Handle sub-flow creation after processing
    if @scenario.awaiting_subflow?
      active_child = @scenario.active_child_scenario
      if active_child
        redirect_to player_scenario_step_path(active_child)
      else
        redirect_to player_scenario_step_path(@scenario)
      end
      return
    end

    if @scenario.completed? || @scenario.stopped?
      # If this is a child scenario completing, return to parent
      if @scenario.parent_scenario.present?
        parent = @scenario.parent_scenario
        parent.process_subflow_completion
        redirect_to parent.complete? ? player_scenario_show_path(parent) : player_scenario_step_path(parent)
      else
        redirect_to player_scenario_show_path(@scenario)
      end
    else
      redirect_to player_scenario_step_path(@scenario)
    end
  end

  def back
    if @scenario.execution_path.present? && @scenario.execution_path.size > 0
      # Pop to the last interactive step (skip sub_flow entries)
      popped_step = nil
      while @scenario.execution_path.size > 0
        candidate = @scenario.execution_path.pop
        next if candidate["step_type"] == "sub_flow"
        popped_step = candidate
        break
      end

      if popped_step
        # Rebuild results from remaining path
        @scenario.results = {}
        @scenario.inputs = {}
        @scenario.execution_path.each do |entry|
          next unless entry["answer"].present?
          variable = entry["variable_name"] || entry["step_title"]
          @scenario.results[variable] = entry["answer"] if variable
          @scenario.inputs[variable] = entry["answer"] if variable
        end

        # Restore position from the popped step
        if popped_step["step_uuid"].present?
          @scenario.current_node_uuid = popped_step["step_uuid"]
        end
        @scenario.current_step_index = [@scenario.current_step_index.to_i - 1, 0].max
        @scenario.status = "active" if @scenario.completed?
        @scenario.save!
      end
    end
    redirect_to player_scenario_step_path(@scenario)
  end

  def show
    @workflow = @scenario.workflow
  end

  def show_shared
    @workflow = Workflow.published.find_by!(share_token: params[:share_token])
    @embed_mode = params[:embed] == "1" && @workflow.embeddable?

    scenario = Scenario.create!(
      workflow: @workflow,
      user: @workflow.user,
      purpose: "live",
      started_at: Time.current,
      current_step_index: 0,
      current_node_uuid: @workflow.start_node&.uuid,
      execution_path: [],
      results: {},
      inputs: {}
    )

    redirect_to player_scenario_step_path(scenario)
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  private

  def set_scenario
    @scenario = Scenario.find(params[:id])
    return if current_user && @scenario.user == current_user
    return if @scenario.workflow.shared? && !current_user

    head :forbidden
  end

  def resolve_current_step
    uuid = @scenario.current_node_uuid
    if uuid.present?
      @scenario.workflow.steps.find_by(uuid: uuid)
    else
      @scenario.workflow.start_step || @scenario.workflow.steps.ordered.first
    end
  end
end
