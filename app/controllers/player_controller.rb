class PlayerController < ApplicationController
  include SubflowOrchestration
  layout "player"

  before_action :authenticate_user!, except: %i[show_shared step next_step back show]
  before_action :set_scenario, only: %i[step next_step back show]

  def index
    # Use subquery for "has steps" filter to avoid group/includes conflict
    ids_with_steps = Step.select(:workflow_id).distinct
    @workflows = Workflow.published
                         .where(id: Workflow.visible_to(current_user).select(:id))
                         .where(id: ids_with_steps)
                         .includes(:tags, :versions, :start_step, :steps, :groups)
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

    if @scenario.awaiting_subflow?
      handle_awaiting_subflow(@scenario)
      return
    end

    # Auto-advance sub_flow steps (they don't need user interaction)
    if @current_step&.step_type == "sub_flow"
      @scenario.process_step(nil)
      return if redirect_to_subflow_if_awaiting(@scenario)

      redirect_to @scenario.complete? ? subflow_completion_path(@scenario) : subflow_step_path(@scenario)
      return
    end

    # Auto-advance resolve steps in child scenarios (so sub-flows complete seamlessly)
    if @scenario.parent_scenario.present? && @current_step&.step_type == "resolve"
      @scenario.process_step(nil)
      if @scenario.complete?
        handle_child_completion(@scenario)
      else
        redirect_to subflow_step_path(@scenario)
      end
      return
    end

    @scenario.step_started_at_pending = Time.current.iso8601(3)
  end

  def next_step
    answer = params[:answer] || params[:selected_option]
    @scenario.record_step_ended
    @scenario.process_step(answer, resolved_here: params[:resolved].present?)

    return if redirect_to_subflow_if_awaiting(@scenario)

    if @scenario.completed? || @scenario.stopped?
      handle_child_completion(@scenario)
    else
      redirect_to subflow_step_path(@scenario)
    end
  end

  def back
    navigator = ScenarioNavigator.new(@scenario, @scenario.workflow)
    navigator.go_back
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
      shared_access: true,
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

  # SubflowOrchestration template methods
  def subflow_step_path(scenario)
    player_scenario_step_path(scenario)
  end

  def subflow_completion_path(scenario)
    player_scenario_show_path(scenario)
  end

  def set_scenario
    if current_user
      @scenario = current_user.scenarios.find_by(id: params[:id])
      head(:forbidden) and return unless @scenario
    else
      @scenario = Scenario.find_by(id: params[:id])
      head(:forbidden) and return unless @scenario&.shared_access?
    end
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
