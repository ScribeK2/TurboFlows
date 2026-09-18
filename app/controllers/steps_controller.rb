class StepsController < ApplicationController
  # Derived from StepFieldMap, so a field added there is permitted here without
  # anyone remembering this list exists. `description` was rendered by the
  # Resolve editor and missing from this list for months: the value was dropped
  # on save with no error, because a permit list fails silently by design.
  #
  # The extras are request-shaped rather than step-shaped — :type selects the
  # STI class, :lock_version drives optimistic locking, and the last two are
  # submission formats, not columns.
  # :position is excluded deliberately. It is in the map because it must survive
  # a round trip, but it is set from graph order by StepBuilder and by #reorder
  # — never submitted on an ordinary edit. Deriving it in would have widened
  # what a PATCH can set, which the old hand-written list did not allow.
  PERMITTED_STEP_PARAMS = (
    StepFieldMap.scalar_fields - %i[position] +
    StepFieldMap.all_rich_text_fields +
    %i[type lock_version transitions_json]
  ).uniq.freeze

  PERMITTED_STEP_PARAM_SHAPES = StepFieldMap::NESTED_SHAPES

  SAVE_CONFLICT_MESSAGE = "Someone else saved this step at the same moment, so your change wasn't saved. " \
                          "Reload to see the latest version, then make your change again.".freeze

  # Which fields, when this save touches them, change what Step::Doors would
  # read off this step — so the open panel's doors list is now stale.
  #
  # variable_name is deliberately absent: a save that actually renames it sets
  # rename_pair, which #connections_or_doors_stream answers first (the whole
  # fragment, not just the doors) - this list only needs to cover the fields a
  # doors-only replace has to answer for.
  DOOR_DECIDING_PARAMS = %i[answer_type options transitions_json].freeze

  include ActionView::RecordIdentifier

  before_action :set_workflow
  before_action :ensure_can_edit!, except: :panel_edit
  before_action :ensure_can_view!, only: :panel_edit
  before_action :set_step, only: %i[show update destroy reorder panel_edit]

  # GET /workflows/:workflow_id/steps/:id
  def show
    respond_to do |format|
      format.html { render partial: "workflows/step_row", locals: { step: @step, workflow: @workflow } }
      format.json { render json: step_json(@step) }
    end
  end

  # GET /workflows/:workflow_id/steps/new
  def new
    step_type = params[:step_type] || "action"
    step_class = step_class_for(step_type)
    position = @workflow.steps.maximum(:position).to_i + 1

    @step = step_class.new(workflow: @workflow, position: position, title: "")

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "steps-list",
          partial: "workflows/step_row",
          locals: { step: @step, workflow: @workflow }
        )
      end
      format.html { render partial: "workflows/step_row", locals: { step: @step, workflow: @workflow } }
    end
  end

  # GET /workflows/:workflow_id/steps/:id/panel_edit
  #
  # readonly=1 is what the builder sends in view mode. Permission alone used to
  # decide this, so an editor looking at a workflow in view mode got a live,
  # autosaving form behind a header that said otherwise.
  def panel_edit
    readonly = params[:readonly].present? || !@workflow.can_be_edited_by?(current_user)
    render partial: "steps/panel_edit",
           locals: { step: @step, workflow: @workflow, readonly: readonly },
           layout: false
  end

  # POST /workflows/:workflow_id/steps
  #
  # from_step_id (with label and condition, from a named door) grows the new
  # step from that one: it lands directly after it, already connected.
  def create
    step_type = step_params[:type] || params[:step_type] || "action"
    @step = GrowStep.create(workflow: @workflow, step_type: step_type, from_step: grow_from_step,
                            attrs: permitted_step_params, label: params[:label], condition: params[:condition])

    respond_to do |format|
      format.turbo_stream { render turbo_stream: grown_streams(@step) }
      format.html { redirect_to workflow_path(@workflow, edit: true), notice: "Step added." }
      format.json { render json: step_json(@step), status: :created }
    end

    broadcast_step_list
  rescue ActiveRecord::RecordInvalid => e
    respond_to_refusal(e.record.errors.full_messages.to_sentence)
  rescue GrowStep::Refused => e
    respond_to_refusal(e.message)
  end

  # PATCH /workflows/:workflow_id/steps/:id
  def update
    if @step.update(permitted_step_params)
      # Captured now, before anything below reloads @step and clears its
      # saved-change tracking: nil unless this save renamed a Question's own
      # variable_name, else [old_name, new_name].
      rename_pair = @step.try(:renamed_variable_pair)

      if step_params[:transitions_json].present?
        refusal = sync_transitions(rename_pair)
        # The step's own fields are already saved by the time this runs —
        # @step.update returned true before sync_transitions was ever called.
        # So this answers the existing refusal path rather than the success
        # one, and says the truth: the step was saved, its connections were not.
        return respond_to_refusal(refusal) if refusal
      end

      respond_to do |format|
        format.turbo_stream do
          streams = [
            turbo_stream.replace(
              dom_id(@step),
              partial: "workflows/step_row",
              locals: { step: @step.reload, workflow: @workflow }
            )
          ]

          if @step.is_a?(Steps::SubFlow) && step_params.key?(:sub_flow_workflow_id)
            streams << turbo_stream.update(
              "subflow-preview",
              partial: "steps/fields/sub_flow_preview",
              locals: { step: @step }
            )
          end

          connections_streamed = false

          # Come back decides whether the step takes connections at all, so the
          # open panel's Connections section has to follow it.
          if @step.is_a?(Steps::SubFlow) && step_params.key?(:sub_flow_returns)
            streams << turbo_stream.update(
              dom_id(@step, :connections),
              partial: "steps/connections",
              locals: { step: @step, workflow: @workflow }
            )
            connections_streamed = true
          end

          # A rename leaves the editor's own snapshot - what it sends on the
          # NEXT autosave of any field - still naming the old identifier. A
          # save that instead touched what decides the doors (answer_type,
          # options, variable_name, transitions_json) only needs the doors
          # list replaced - unless it just turned one of the editor's own rows
          # into a door, which would then show in both places at once.
          # #connections_or_doors_stream is the one place that decides which,
          # if either, this save needs.
          unless connections_streamed
            stream = connections_or_doors_stream(rename_pair)
            streams << stream if stream
          end

          # The "Default for X" card describes the chosen type; the panel is
          # not re-rendered on save, so the card is streamed like the sub-flow
          # preview is.
          if @step.is_a?(Steps::Resolve) && step_params.key?(:resolution_type)
            streams << turbo_stream.replace(
              dom_id(@step, :resolution_default),
              partial: "steps/fields/resolve_default",
              locals: { step: @step }
            )
          end

          render turbo_stream: streams
        end
        format.html { redirect_to workflow_path(@workflow, edit: true), notice: "Step updated." }
        format.json { render json: step_json(@step) }
      end

      broadcast_step_row(@step)
    else
      # The panel is not re-rendered on save, and the frame this used to stream
      # into does not exist there, so a refused save was silent.
      message = "This step was not saved: #{@step.errors.full_messages.to_sentence}."
      respond_to do |format|
        format.turbo_stream { render_refusal(message, status: :unprocessable_content) }
        format.html { redirect_to workflow_path(@workflow, edit: true), alert: message }
        format.json { render json: { errors: @step.errors.full_messages }, status: :unprocessable_content }
      end
    end
  rescue ActiveRecord::StaleObjectError
    respond_to_save_conflict
  rescue ActiveRecord::RecordInvalid => e
    # Raised from inside an after_update callback - Question#carry_conditions_to_new_variable
    # calling transition.update! and hitting Transition's own uniqueness
    # validation when a rename collides two conditions onto one target. That
    # callback runs in the same transaction as @step's own save, so the whole
    # thing - the rename included - rolls back; nothing here was saved.
    respond_to_refusal("This step was not saved: #{e.record.errors.full_messages.to_sentence}.")
  end

  # DELETE /workflows/:workflow_id/steps/:id
  def destroy
    if @workflow.start_step_id == @step.id
      @workflow.update_column(:start_step_id, nil)
    end
    @step.destroy
    ensure_start_step_assigned
    Step.rebalance_positions(@workflow)
    remaining_steps = @workflow.steps.reload.count

    respond_to do |format|
      format.turbo_stream do
        streams = [
          turbo_stream.remove(dom_id(@step)),
          turbo_stream.update("step-count-text",
                              helpers.pluralize(remaining_steps, "step"))
        ]
        if remaining_steps.zero?
          streams << turbo_stream.append("steps-list",
                                         partial: "workflows/empty_state",
                                         locals: { workflow: @workflow })
          streams << turbo_stream.update("builder-panel", "")
        end
        render turbo_stream: streams
      end
      format.html { redirect_to workflow_path(@workflow, edit: true), notice: "Step removed." }
      format.json { head :no_content }
    end

    Turbo::StreamsChannel.broadcast_remove_to(
      "workflow_#{@workflow.id}",
      target: dom_id(@step)
    )
  end

  # POST /workflows/:workflow_id/steps/apply_template
  def apply_template
    template = WorkflowTemplate.find(params[:template_key])
  rescue KeyError
    head(:unprocessable_content)
  else
    steps_data, first_uuid = build_steps_data_from_template(template)

    Workflow.transaction do
      StepBuilder.call(@workflow, steps_data, start_node_uuid: first_uuid, replace: true)
      @workflow.update!(graph_mode: true)
    end

    @workflow.reload
    steps = @workflow.steps.order(:position).includes(:incoming_transitions, transitions: :target_step)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.update("steps-list",
                              partial: "workflows/steps_list_items",
                              locals: { workflow: @workflow, steps: steps }),
          turbo_stream.update("builder-panel", ""),
          turbo_stream.update("step-count-text",
                              helpers.pluralize(steps.size, "step"))
        ]
      end
      format.html { redirect_to workflow_path(@workflow, edit: true), notice: "Template applied." }
    end
  end

  # PATCH /workflows/:workflow_id/steps/:id/reorder
  def reorder
    StepReorderer.call(@workflow, @step, params[:position])
    broadcast_step_list

    head :ok
  end

  private

  def set_workflow
    @workflow = Workflow.find(params[:workflow_id])
  end

  def grow_from_step
    @workflow.steps.find(params[:from_step_id]) if params[:from_step_id].present?
  end

  # The whole list, not the one row: a step inserted mid-list moves the number
  # of every step after it, and every "→ Title · 4" that points at one.
  #
  # Rows always render unselected — the panel is the one source of truth for
  # which row is selected, and builder_controller#syncSelectedRow reads it
  # client-side after this (and every other) stream renders. A selected_step
  # local here used to paint the new row directly, but the very next line
  # broadcasts the same #steps-list subtree over Action Cable with no such
  # local, so a solo editor's own browser raced its own two renders.
  def grown_streams(step)
    [
      turbo_stream.replace("step-list", partial: "workflows/step_list",
                                        locals: { workflow: @workflow, steps: list_steps }),
      turbo_stream.replace("builder-panel", partial: "steps/panel_edit",
                                            locals: { step: step, workflow: @workflow, readonly: false }),
      turbo_stream.update("step-count-text", helpers.pluralize(@workflow.steps.count, "step"))
    ]
  end

  def list_steps
    @workflow.steps.reload.ordered.includes(transitions: :target_step)
  end

  def broadcast_step_list
    Turbo::StreamsChannel.broadcast_update_to(
      "workflow_#{@workflow.id}",
      target: "steps-list",
      partial: "workflows/steps_list_items",
      locals: { workflow: @workflow.reload, steps: list_steps }
    )
  end

  def set_step
    @step = @workflow.steps.find(params[:id])
  end

  def ensure_can_edit!
    unless @workflow.can_be_edited_by?(current_user)
      redirect_to workflows_path, alert: "You don't have permission to edit this workflow."
    end
  end

  def ensure_can_view!
    return if @workflow.can_be_viewed_by?(current_user)

    redirect_to workflows_path, alert: "You don't have permission to view this workflow."
  end

  # Two saves of one step in the same instant, and this one lost the
  # optimistic-locking race. Left unhandled, Rails answered with an empty 409 the
  # builder ignored, and the edit vanished without a word. The step panel never
  # sends lock_version, so this only fires when both saves overlap in the
  # database; saves seconds apart still go through, the later one winning.
  def respond_to_save_conflict
    respond_to_refusal(SAVE_CONFLICT_MESSAGE, status: :conflict)
  end

  def render_refusal(message, status:)
    flash.now[:alert] = message
    render turbo_stream: turbo_stream.update("flash", partial: "shared/flash_messages"), status: status
  end

  # The one shape every refusal in this controller shares: a turbo-stream flash,
  # an HTML redirect back to the builder with the same alert, and a JSON body
  # naming the single message. update's own validation-failure branch stays
  # separate — its JSON body is @step.errors.full_messages (every individual
  # error), not this message wrapped in a one-element array, so folding it in
  # would change that response's shape.
  def respond_to_refusal(message, status: :unprocessable_content)
    respond_to do |format|
      format.turbo_stream { render_refusal(message, status: status) }
      format.html { redirect_to workflow_path(@workflow, edit: true), alert: message }
      format.json { render json: { errors: [message] }, status: status }
    end
  end

  def step_params
    params.fetch(:step, {}).permit(*PERMITTED_STEP_PARAMS, **PERMITTED_STEP_PARAM_SHAPES)
  end

  def permitted_step_params
    step_params.except(:type, :transitions_json)
  end

  def step_class_for(type)
    Step.class_for_type(type)
  end

  def step_locals(step, expanded: false)
    {
      step: step,
      index: step.position,
      workflow: @workflow,
      expanded: expanded
    }
  end

  def ensure_start_step_assigned
    return if @workflow.start_step_id.present?

    first_step = @workflow.steps.first
    @workflow.update_column(:start_step_id, first_step.id) if first_step
  end

  # Returns nil on success, or the message to refuse the response with.
  def sync_transitions(rename_pair)
    TransitionSync.call(@step, step_params[:transitions_json], renamed_variable: rename_pair)
    nil
  rescue TransitionSync::Malformed, ActiveRecord::RecordInvalid => e
    "This step was saved, but its connections were not: #{e.message}"
  end

  def doors_changed?
    DOOR_DECIDING_PARAMS.any? { |key| step_params.key?(key) }
  end

  # True when this save turned a row the editor was showing as an ordinary
  # connection into one of the doors Step::Doors now finds - which would
  # otherwise render twice: once as a door, once still sitting in the editor's
  # stale snapshot below it. Checked against the transitions as saved, not as
  # sent, since a rewritten condition (a rename) is what can make this true.
  def editor_row_became_door?
    return false if step_params[:transitions_json].blank?

    sent = JSON.parse(step_params[:transitions_json])["rows"].to_a.pluck("uuid")
    Step::Doors.for(@step.reload).doors.filter_map(&:transition).any? { |t| sent.include?(t.uuid) }
  rescue JSON::ParserError, NoMethodError
    false
  end

  # The one place that decides which, if either, of the doors list and the
  # whole Connections fragment this save needs re-rendered. A rename always
  # needs the whole fragment - the editor's own snapshot still names the old
  # variable, and #editor_row_became_door? cannot help with that since a
  # renamed condition does not change which uuids are doors. Otherwise, a save
  # that changed what decides the doors gets the doors list alone, unless it
  # just turned one of the editor's own rows into a door.
  def connections_or_doors_stream(rename_pair)
    return full_connections_stream if rename_pair
    return nil unless doors_changed?

    editor_row_became_door? ? full_connections_stream : doors_stream
  end

  def full_connections_stream
    turbo_stream.update(dom_id(@step, :connections), partial: "steps/connections",
                                                     locals: { step: @step, workflow: @workflow })
  end

  def doors_stream
    turbo_stream.replace(dom_id(@step, :doors), partial: "steps/doors",
                                                locals: { step: @step, workflow: @workflow })
  end

  def broadcast_step_row(step)
    Turbo::StreamsChannel.broadcast_replace_to(
      "workflow_#{@workflow.id}",
      target: dom_id(step),
      partial: "workflows/step_row",
      locals: { step: step, workflow: @workflow }
    )
  end

  def step_json(step)
    {
      id: step.id,
      uuid: step.uuid,
      type: step.type.demodulize.underscore,
      title: step.title,
      position: step.position
    }
  end

  # Templates lead the builder's empty state, so an applied template is the first
  # workflow most authors ever see. This used to copy type, title and position
  # and nothing else, which made every template a skeleton of empty bodies —
  # a demonstration of the exact defect authors should avoid. The content fields
  # come from StepFieldMap so a field added there reaches templates too, rather
  # than being dropped at the one reader nobody remembered to edit.
  def build_steps_data_from_template(template)
    uuid_map = {}
    template["steps"].each { |s| uuid_map[s["uuid"]] = SecureRandom.uuid }

    steps_data = template["steps"].map do |s|
      step_hash = {
        "id" => uuid_map[s["uuid"]],
        "type" => s["type"],
        "title" => s["title"],
        "position" => s["position"]
      }

      template_content_keys(s["type"]).each do |key|
        value = s[key.to_s]
        step_hash[key.to_s] = value unless value.nil?
      end

      step_transitions = template["transitions"].select { |t| t["from"] == s["uuid"] }
      if step_transitions.any?
        step_hash["transitions"] = step_transitions.map.with_index do |t, i|
          {
            "target_uuid" => uuid_map[t["to"]],
            "condition" => t["condition"],
            "label" => t["label"],
            "position" => i
          }.compact
        end
      end

      step_hash
    end

    first_uuid = uuid_map[template["steps"].first["uuid"]]
    [steps_data, first_uuid]
  end

  def template_content_keys(step_type)
    StepFieldMap::COMMON -
      %i[title position] +
      StepFieldMap::BY_TYPE.fetch(step_type, []) +
      StepFieldMap::RICH_TEXT.fetch(step_type, [])
  end
end
