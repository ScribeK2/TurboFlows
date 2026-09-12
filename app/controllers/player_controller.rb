class PlayerController < ApplicationController
  include RunnerShell

  # Layout comes from ApplicationController's `layout :resolve_layout`, which
  # this overrides below. A class-level `layout "player", except: :index` does
  # NOT fall back to the parent's symbol for the excluded action — it resolves
  # to no layout at all, and the page renders bare.

  before_action :authenticate_user!, except: %i[show_shared step next_step back show]
  before_action :set_scenario, only: %i[step next_step back show stop]

  def index
    # Prefills the client-side filter, so a Cmd+K result can name the workflow
    # the user picked instead of dropping them on an unfiltered list.
    @query = params[:q].to_s
    # Use subquery for "has steps" filter to avoid group/includes conflict
    ids_with_steps = Step.select(:workflow_id).distinct
    @workflows = Workflow.published
                         .where(id: Workflow.visible_to(current_user).select(:id))
                         .where(id: ids_with_steps)
                         .where.not(title: "Untitled Workflow")
                         .includes(:tags, :published_version, :start_step, :steps, :groups)
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
    elsewhere = runner_step_redirect(@scenario)
    return redirect_to(elsewhere) if elsewhere

    # Re-checked, not trusted: asking for embed is not the same as the workflow
    # having enabled it.
    #
    # Checked against the workflow the run STARTED in, not this frame's. Embed
    # describes the run the visitor opened — like shared_access and purpose do —
    # and a sub-flow's own workflow carries no share token, so reading it off the
    # frame turned embed off the moment the run entered a sub-flow.
    #
    # `root_workflow` fixed that for sub-flows and is not enough once a handoff
    # exists: a handed-to run has no parent, so it IS its own root, and its
    # workflow has no share token either. `run_origin` is the only reader that
    # still reaches the workflow whose share link the visitor actually opened.
    @embed_mode = params[:embed] == "1" && @scenario.run_origin.workflow.embeddable?
    assign_runner_step_state(@scenario)
  end

  def next_step
    advance_runner(@scenario, runner_answer, resolved_here: runner_resolved_here?)
  end

  def back
    rewind_runner(@scenario)
  end

  def stop
    # Stops the whole scenario tree, so report on the run the user actually
    # started rather than the frame they happened to be inside. `run_origin`, not
    # `root_scenario`: after a handoff the frame is its own root.
    @scenario.stop!(@scenario.current_step_index)
    redirect_to runner_results_path(@scenario.run_origin), notice: "Workflow stopped."
  end

  # See ScenariosController#show: a run's results live at its origin.
  def show
    origin = @scenario.run_origin
    return redirect_to(player_scenario_show_path(origin)) if origin != @scenario

    @workflow = @scenario.workflow
    @ending = @scenario.run_ending
  end

  def show_shared
    @workflow = Workflow.published.find_by!(share_token: params[:share_token])
    @embed_mode = params[:embed] == "1" && @workflow.embeddable?

    scenario = Scenario.create!(
      workflow: @workflow,
      # The visitor, or nobody — never the owner. Stamping `@workflow.user` here
      # recorded every anonymous run as the owner's, which skewed per-agent
      # analytics for anyone who shared a workflow widely. A signed-in visitor
      # following a share link is a real agent and is recorded as one.
      user: current_user,
      purpose: "live",
      shared_access: true,
      started_at: Time.current,
      current_step_index: 0,
      current_node_uuid: @workflow.start_node&.uuid,
      execution_path: [],
      results: {},
      inputs: {}
    )

    # Carry embed through the hop. This action redirects, so a flag set here
    # renders nothing — the visitor lands on #step, which has to be told.
    landed = ScenarioSettler.new(scenario).settle_from_start
    redirect_to player_scenario_step_path(landed, embed: ("1" if @embed_mode))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  private

  # The focused shell is for *running*, not for the Player as a namespace.
  # `index` is a browse page — a heading, a filter, and a list of rows — and it
  # only wore the player chrome because the layout was declared for the whole
  # controller. It is also the one rendering action here that always requires a
  # session (`step` and `show` stay open so anonymous share links work), so the
  # same line is already drawn twice.
  #
  # Keeping it on the app layout makes the chrome falling away at the start of a
  # run *mean* something — you have entered a mode — instead of being an
  # artifact of where a `layout` call happened to sit. It also puts a top bar on
  # the page a regular user actually works on: their only other destination is
  # the dashboard, so before this they had one.
  def resolve_layout
    action_name == "index" ? "application" : "player"
  end

  # RunnerShell template methods
  def runner_step_path(scenario)
    player_scenario_step_path(scenario)
  end

  def runner_results_path(scenario)
    player_scenario_show_path(scenario)
  end

  def set_scenario
    @scenario = Scenario.find_by(id: params[:id])
    head(:forbidden) and return unless @scenario && scenario_readable?(@scenario)
  end

  # `shared_access` is a property of the RUN, not of the visitor — the same point
  # `shared_player_subflow_test` makes about carrying it across a handoff — so it
  # has to be checked whether or not anyone is signed in.
  #
  # This used to branch on `current_user` FIRST and only reach the shared grant
  # when nobody was signed in, which meant signing in *revoked* access to a share
  # link. On the same URL: an anonymous visitor got 200, the workflow's owner got
  # 200, and every other signed-in user got 403. On an install where everyone has
  # an account, that is most of the people a link is sent to.
  #
  # Nothing is widened by checking both: a signed-in visitor could already reach
  # any `shared_access` run by signing out and opening the same URL.
  def scenario_readable?(scenario)
    return true if scenario.shared_access?

    current_user.present? && scenario.user_id == current_user.id
  end
end
