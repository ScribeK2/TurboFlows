class PlayerController < ApplicationController
  include RunnerAdvance

  layout "player"

  before_action :authenticate_user!, except: %i[show_shared step next_step back show]
  before_action :set_scenario, only: %i[step next_step back show stop]

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
    # Settle before redirecting: a workflow whose first step is a sub_flow opens
    # on a node with no UI, and GET step no longer moves the run.
    redirect_to player_scenario_step_path(ScenarioSettler.new(scenario).settle_from_start)
  end

  # A pure read. It renders the run; it never moves it. See
  # ScenariosController#step for why that matters.
  def step
    @workflow = @scenario.workflow

    if @scenario.completed? || @scenario.stopped?
      # A finished child is a finished sub-flow, not a finished run — see
      # ScenariosController#handle_step_guard_redirects.
      parent = @scenario.parent_scenario if @scenario.completed?
      if parent
        redirect_to runner_step_path(parent)
        return
      end

      # Stacked keeps a finished run on its transcript; stopped still leaves,
      # since there is no ending to read.
      unless stacked_runner? && @scenario.completed?
        redirect_to player_scenario_show_path(@scenario.root_scenario)
        return
      end
    end

    # A run waiting on a child that is still going belongs at the child's URL.
    # A redirect writes nothing; a finished child needs a POST, and #parked?
    # surfaces that as a Resume control instead of healing it here.
    active_child = @scenario.awaiting_subflow? ? @scenario.active_child_scenario : nil
    if active_child && !active_child.complete?
      redirect_to runner_step_path(active_child)
      return
    end

    @parked = @scenario.parked?
    @current_step = resolve_current_step
    @scenario.step_started_at_pending = Time.current.iso8601(3)
  end

  def next_step
    @workflow = @scenario.workflow
    @scenario.inputs ||= {}
    @scenario.inputs["escalation_reason"] = params[:escalation_reason] if params[:escalation_reason].present?
    @scenario.inputs["resolution_notes"] = params[:resolution_notes] if params[:resolution_notes].present?
    @scenario.record_step_ended

    advance_runner(@scenario, params[:answer] || params[:selected_option],
                   resolved_here: params[:resolved].present?)
  end

  def back
    navigator = ScenarioNavigator.new(@scenario)
    navigator.go_back
    redirect_to player_scenario_step_path(@scenario)
  end

  def stop
    # Stops the whole scenario tree, so report on the run the user actually
    # started rather than the sub-flow frame they happened to be inside.
    @scenario.stop!(@scenario.current_step_index)
    redirect_to player_scenario_show_path(@scenario.root_scenario), notice: "Workflow stopped."
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

    redirect_to player_scenario_step_path(ScenarioSettler.new(scenario).settle_from_start)
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  private

  # A refused step re-renders where the user already is, with the reasons.
  # 422 because Turbo discards a 200 that is not a redirect.
  def render_blocked_step(errors)
    @workflow = @scenario.workflow
    @current_step = resolve_current_step
    @step_errors = errors
    @submitted = submitted_form_values
    render :step, status: :unprocessable_content
  end

  # Values from the refused submit, so a blocked form keeps what was typed.
  def submitted_form_values
    raw = params[:answer]
    raw.is_a?(ActionController::Parameters) ? raw.permit!.to_h : {}
  end

  # RunnerAdvance template methods
  def runner_step_path(scenario)
    player_scenario_step_path(scenario)
  end

  def runner_results_path(scenario)
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
