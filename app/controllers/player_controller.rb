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

    @scenario.step_started_at_pending = Time.current.iso8601(3)
  end

  def next_step
    answer = params[:answer] || params[:selected_option]
    @scenario.record_step_ended
    @scenario.process_step(answer, resolved_here: params[:resolved].present?)

    if @scenario.completed? || @scenario.stopped?
      redirect_to player_scenario_show_path(@scenario)
    else
      redirect_to player_scenario_step_path(@scenario)
    end
  end

  def back
    if @scenario.execution_path.present? && @scenario.execution_path.size > 1
      @scenario.execution_path.pop
      @scenario.current_step_index = [@scenario.current_step_index.to_i - 1, 0].max
      @scenario.save!
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
