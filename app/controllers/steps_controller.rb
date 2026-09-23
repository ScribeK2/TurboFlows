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
  # a round trip, but it is set from graph order by StepBuilder — never
  # submitted on an ordinary edit. Deriving it in would have widened what a
  # PATCH can set, which the old hand-written list did not allow.
  PERMITTED_STEP_PARAMS = (
    StepFieldMap.scalar_fields - %i[position] +
    StepFieldMap.all_rich_text_fields +
    %i[type lock_version transitions_json]
  ).uniq.freeze

  PERMITTED_STEP_PARAM_SHAPES = StepFieldMap::NESTED_SHAPES

  SAVE_CONFLICT_MESSAGE = "Someone else saved this step at the same moment, so your change wasn't saved. " \
                          "Reload to see the latest version, then make your change again.".freeze

  # There are TWO conflict messages here and they must stay different.
  #
  # SAVE_CONFLICT_MESSAGE above is for a lost optimistic-locking race: two writes
  # overlapping IN THE DATABASE, caught by StaleObjectError. Reloading is the
  # right advice there, because this request never held the current row.
  #
  # This one is for two edits SECONDS APART, where nothing overlaps and the
  # database is perfectly happy. The author's typing is still in the field in
  # front of them and their next keystroke retries against the fresh value — so
  # telling them to reload would throw away the very text this exists to save.
  FIELD_CONFLICT_MESSAGE = "This wasn't saved: someone else changed %<field>s while you were editing. " \
                           "Your text is still here — change it again to save over theirs.".freeze

  # TransitionSync skipped a row this save's payload claimed was rendered but
  # that had already been deleted elsewhere - the stale-panel case. The save
  # itself still succeeded; only that one connection did not come back.
  STALE_PANEL_NOTICE = "A connection you had open was removed elsewhere, so it wasn't saved.".freeze

  # Which fields, when this save touches them, change what Step::Doors would
  # read off this step — so the open panel's doors list is now stale.
  #
  # variable_name is deliberately absent: a save that actually renames it sets
  # rename_pair, which #connections_or_doors_stream answers first (the whole
  # fragment, not just the doors) - this list only needs to cover the fields a
  # doors-only replace has to answer for.
  DOOR_DECIDING_PARAMS = %i[answer_type options transitions_json].freeze

  # Fields whose change alters what the OUTLINE shows beyond this step's own
  # row: its title is on every jump chip, fold summary and ways-in tooltip
  # naming it; answer type and options are its doors; sub_flow_returns turns
  # a leaf into a step with a door.
  OUTLINE_FIELDS = %w[title answer_type options sub_flow_returns].freeze

  include ActionView::RecordIdentifier

  before_action :set_workflow
  before_action :ensure_can_edit!, except: :panel_edit
  before_action :ensure_can_view!, only: :panel_edit
  before_action :set_step, only: %i[show update destroy panel_edit]

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
    respond_to_refused_grow(e.message)
  end

  # PATCH /workflows/:workflow_id/steps/:id
  def update
    # Before @step.update, never after: a check that ran afterwards would be
    # reporting a conflict it had already caused. A save refused here writes
    # NOTHING — not the step's own fields, and not its connections, since
    # sync_transitions lives inside the success branch below.
    if (stale_field = conflicting_field)
      # Named for the panel, which drops its baseline for this field so the
      # author's NEXT save goes through. Without that the refusal's own advice -
      # "change it again to save over theirs" - is false: nothing else updates
      # the baseline, so every later attempt is compared against a value the
      # database left behind long ago and the author is stuck until they reload.
      # Caught in a browser; the system test asserted the refusal and never
      # tried to recover from it.
      response.headers["X-Conflicting-Field"] = stale_field.to_s
      return respond_to_refusal(format(FIELD_CONFLICT_MESSAGE, field: stale_field.to_s.humanize.downcase),
                                status: :conflict)
    end

    if @step.update(permitted_step_params)
      # Captured now, before anything below reloads @step and clears its
      # saved-change tracking: nil unless this save renamed a Question's own
      # variable_name, else [old_name, new_name].
      rename_pair = @step.try(:renamed_variable_pair)
      # Read now, before the reload below clears saved-change tracking. This is
      # only the FIELD half of whether the outline needs the whole list -
      # transitions_json is folded in below, once TransitionSync has actually
      # run: that field is present on every non-Resolve panel autosave (the
      # editor renders it non-blank and inline-autosave never marks it dirty),
      # so its mere presence can't tell a real retarget from an unchanged
      # snapshot - only TransitionSync's own before/after signature can.
      outline_changed = @step.saved_changes.keys.intersect?(OUTLINE_FIELDS)

      if step_params[:transitions_json].present?
        refusal = sync_transitions(rename_pair)
        # The step's own fields are already saved by the time this runs —
        # @step.update returned true before sync_transitions was ever called.
        # So this answers a refusal rather than the success path, and says the
        # truth: the step was saved, its connections were not.
        return respond_to_connections_refusal(refusal, rename_pair) if refusal

        outline_changed ||= @sync_result.changed
      end

      respond_to do |format|
        format.turbo_stream do
          streams = [
            turbo_stream.replace(
              dom_id(@step),
              partial: "workflows/step_row",
              locals: { step: @step.reload, workflow: @workflow, outline: outline }
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
              locals: { step: @step, workflow: @workflow, outline: outline }
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
          # if either, this save needs. A skipped row (TransitionSync found a
          # rendered-but-gone uuid) always needs the whole fragment: the
          # editor's own snapshot is now wrong in a way neither the rename nor
          # the doors-shape check can see, and re-rendering it whole is what
          # resets the editor's `minted` list too.
          unless connections_streamed
            stream = healing_stale_panel? ? full_connections_stream : connections_or_doors_stream(rename_pair)
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

          streams << stale_panel_flash_stream if healing_stale_panel?

          render turbo_stream: streams
        end
        format.html do
          redirect_to workflow_path(@workflow, edit: true),
                      notice: healing_stale_panel? ? STALE_PANEL_NOTICE : "Step updated."
        end
        format.json { render json: step_json(@step, notice: healing_stale_panel? ? STALE_PANEL_NOTICE : nil) }
      end

      broadcast_step_row(@step)
      broadcast_step_list if outline_changed
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
    parent_steps = incoming_parent_steps(@step)

    if @workflow.start_step_id == @step.id
      @workflow.update_column(:start_step_id, nil)
    end
    @step.destroy
    ensure_start_step_assigned
    Step.rebalance_positions(@workflow)

    respond_to do |format|
      format.turbo_stream { render turbo_stream: destroy_streams(parent_steps) }
      format.html { redirect_to workflow_path(@workflow, edit: true), notice: "Step removed." }
      format.json { head :no_content }
    end

    broadcast_step_list
    broadcast_parent_connections(parent_steps)
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
    @outline = StepOutline.call(@workflow, steps)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.update("steps-list",
                              partial: "workflows/steps_list_items",
                              locals: { workflow: @workflow, steps: steps, outline: outline }),
          # The list-level dialog sits beside #steps-list, not in it.
          turbo_stream.replace("list-target-picker-options", partial: "steps/target_picker_options",
                                                             locals: list_target_picker_options_locals),
          turbo_stream.update("builder-panel", ""),
          turbo_stream.update("step-count-text",
                              helpers.pluralize(steps.size, "step"))
        ]
      end
      format.html { redirect_to workflow_path(@workflow, edit: true), notice: "Template applied." }
    end
  end

  private

  def set_workflow
    @workflow = Workflow.find(params[:workflow_id])
  end

  # What the author pressed is what was stale - a stub for a door that has
  # since been wired - so the refusal replaces the list that holds it and the
  # parent's own Connections fragment (a no-op unless that panel is open),
  # rather than leaving the same stub there to be pressed again.
  def respond_to_refused_grow(message)
    respond_to do |format|
      format.turbo_stream do
        flash.now[:alert] = message
        parent = grow_from_step
        streams = [turbo_stream.replace("step-list", partial: "workflows/step_list",
                                                     locals: { workflow: @workflow, steps: list_steps, outline: outline })]
        if parent
          streams << turbo_stream.update(dom_id(parent, :connections),
                                         partial: "steps/connections",
                                         locals: { step: parent, workflow: @workflow, outline: outline })
        end
        streams << turbo_stream.update("flash", partial: "shared/flash_messages")

        render turbo_stream: streams, status: :unprocessable_content
      end
      format.html { redirect_to workflow_path(@workflow, edit: true), alert: message }
      format.json { render json: { errors: [message] }, status: :unprocessable_content }
    end
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
                                        locals: { workflow: @workflow, steps: list_steps, outline: outline }),
      turbo_stream.replace("builder-panel", partial: "steps/panel_edit",
                                            locals: { step: step, workflow: @workflow, readonly: false,
                                                      outline: outline }),
      turbo_stream.update("step-count-text", helpers.pluralize(@workflow.steps.count, "step"))
    ]
  end

  # Loaded once per request. Like #outline, read only after the action's writes.
  def list_steps
    @list_steps ||= @workflow.steps.reload.ordered.includes(transitions: :target_step).to_a
  end

  # The builder outline for everything this request renders - its response
  # streams and its broadcasts - built ONCE and passed down as `outline:`.
  # Each partial used to build its own, 3 queries and a full walk apiece: a
  # title autosave built it five times, a door pick eight
  # (test/controllers/step_outline_builds_test.rb). Memoised on the
  # controller, never on the model or class, and first read only after the
  # action has finished writing - every action here renders last.
  def outline
    @outline ||= StepOutline.call(@workflow, list_steps)
  end

  # The source steps of @step's own incoming transitions, captured before
  # @step.destroy cascades those transitions away - their rows still show the
  # door @step used to fill until #destroy_streams refreshes them. A step
  # whose own edge loops back to itself is excluded: it is being removed too,
  # so there is nothing to refresh it with.
  def incoming_parent_steps(step)
    step.incoming_transitions.includes(:step).map(&:step).uniq.reject { |parent| parent.id == step.id }
  end

  # destroy answers the way a grow does: the whole list (already empty-state
  # aware), the count, and - since a delete can free a door on a step whose
  # panel happens to be open - that parent's Connections fragment. A stream at
  # a target not on the page is a no-op, so this does not need to know which
  # panel, if any, is open.
  def destroy_streams(parent_steps)
    steps = list_steps
    streams = [
      turbo_stream.replace("step-list", partial: "workflows/step_list",
                                        locals: { workflow: @workflow, steps: steps, outline: outline }),
      turbo_stream.update("step-count-text", helpers.pluralize(steps.size, "step"))
    ]
    streams << turbo_stream.update("builder-panel", "") if steps.empty?

    parent_steps.each do |parent|
      streams << turbo_stream.update(dom_id(parent, :connections),
                                     partial: "steps/connections",
                                     locals: { step: parent, workflow: @workflow, outline: outline })
    end

    streams
  end

  # destroy_streams answers the editor who deleted; every OTHER editor with one
  # of these parents' panels open was watching only the list broadcast, so their
  # Connections section went on naming a step that no longer exists. Same shape
  # as Steps::TransitionsController#broadcast_connections, and the browser
  # declines it the same way when that editor holds unsaved rows.
  def broadcast_parent_connections(parent_steps)
    parent_steps.each do |parent|
      Turbo::StreamsChannel.broadcast_update_to(
        "workflow_#{@workflow.id}",
        target: dom_id(parent, :connections),
        partial: "steps/connections",
        locals: { step: parent.reload, workflow: @workflow, outline: outline }
      )
    end
  end

  def broadcast_step_list
    Turbo::StreamsChannel.broadcast_update_to(
      "workflow_#{@workflow.id}",
      target: "steps-list",
      partial: "workflows/steps_list_items",
      locals: { workflow: @workflow.reload, steps: list_steps, outline: outline }
    )
    # The list-level "An existing step…" dialog (workflows/_list_target_picker)
    # sits beside #steps-list, not in it, so the update above leaves its
    # candidates stale - a step grown in another tab would never be offered.
    Turbo::StreamsChannel.broadcast_replace_to(
      "workflow_#{@workflow.id}",
      target: "list-target-picker-options",
      partial: "steps/target_picker_options",
      locals: list_target_picker_options_locals
    )
  end

  def list_target_picker_options_locals
    { step: nil, workflow: @workflow, options_id: "list-target-picker-options", outline: outline }
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

  # A refusal with something saved behind it: @step.update committed before
  # TransitionSync refused, so the row that shows the step's fields still has to
  # follow - here, and in every other editor's list.
  #
  # The Connections fragment follows only when that save renamed the variable.
  # The rename's callback already rewrote the step's own conditions, while the
  # editor's snapshot still names the old identifier, and the panel sends the
  # whole step on every change - so left alone, its next autosave of any field
  # writes the stale conditions straight back. Any other refusal leaves the
  # editor as it is: the row that was refused is the author's to fix, and
  # re-rendering from the database would take it away before they could.
  def respond_to_connections_refusal(message, rename_pair)
    respond_to do |format|
      format.turbo_stream do
        flash.now[:alert] = message
        streams = [turbo_stream.replace(dom_id(@step), partial: "workflows/step_row",
                                                       locals: { step: @step.reload, workflow: @workflow,
                                                                 outline: outline })]
        streams << full_connections_stream if rename_pair
        streams << turbo_stream.update("flash", partial: "shared/flash_messages")

        render turbo_stream: streams, status: :unprocessable_content
      end
      format.html { redirect_to workflow_path(@workflow, edit: true), alert: message }
      format.json { render json: { errors: [message] }, status: :unprocessable_content }
    end

    broadcast_step_row(@step)
  end

  def step_params
    params.fetch(:step, {}).permit(*PERMITTED_STEP_PARAMS, **PERMITTED_STEP_PARAM_SHAPES,
                                   dirty_fields: [], rendered: {})
  end

  # The panel submits the whole step on every change, so a save carries fields
  # the author never touched — including a copy that may be seconds out of date
  # if someone else is in the same step. Writing only what was touched is what
  # lets two editors work on one step without clobbering each other.
  #
  # An ABSENT dirty_fields key writes everything, exactly as before. That is not
  # defensive coding: step_field_map_test.rb PATCHes every field of every type
  # and is the codebase's publish/restore guarantee, and every other caller
  # (imports, tests, any client that predates this) sends no such key.
  def permitted_step_params
    attributes = step_params.except(:type, :transitions_json, :dirty_fields, :rendered)
    return attributes if dirty_field_names.nil?

    attributes.slice(*dirty_field_names)
  end

  # The first touched field whose value has changed since this panel rendered it,
  # or nil. Compared through the attribute's own type: `options` is a JSON column
  # whose rendered form is a JSON string and `can_resolve` is a boolean arriving
  # as "0"/"1", so a raw == would report a conflict on every save of either.
  #
  # Rich text is compared as HTML, because ActionText::Content#to_s renders
  # through the app's display layout and is not what is stored - see
  # StepSerializer#rich_text_html. Do NOT swap this for to_plain_text to make it
  # "simpler": that strips all markup, and a comparison that normalises away what
  # it guards is not a guard. It is how an unbounded wrapper-nesting bug once
  # passed step_field_map_test.
  def conflicting_field
    rendered = params.dig(:step, :rendered)
    return nil unless rendered.respond_to?(:key?)
    return nil if dirty_field_names.nil?

    dirty_field_names.find do |field|
      next false unless rendered.key?(field)

      if rich_text_field?(field)
        @step.public_send(field)&.body&.to_html.to_s != rendered[field].to_s
      else
        # deserialize on the rendered side, not cast: the panel sends a JSON
        # column's value as a JSON STRING, and Type::Json#cast returns a String
        # unchanged - it only parses in #deserialize. With cast on both sides
        # every options save compared a string against an Array and reported a
        # conflict that could never clear. deserialize is cast for every other
        # type here, so this costs nothing elsewhere.
        type = @step.class.type_for_attribute(field)
        # An empty text input reads "" where its column holds nil, so without
        # this every optional field the author never filled in reported a
        # conflict on its first save and could never be saved again. Only ""
        # and nil are folded together - `false` stays distinct from nil, which
        # an .blank? test would not.
        empty_string_as_nil(type.deserialize(rendered[field])) !=
          empty_string_as_nil(type.cast(@step.read_attribute(field)))
      end
    end
  end

  def empty_string_as_nil(value)
    value.is_a?(String) && value.empty? ? nil : value
  end

  # `step_type` is the spelling every other StepFieldMap reader uses
  # (WorkflowVariableCheck calls rich_text_fields(step.step_type)).
  def rich_text_field?(field)
    StepFieldMap.rich_text_fields(@step.step_type).include?(field.to_sym)
  end

  # nil when the panel said nothing about which fields it touched; otherwise the
  # touched field names, blanks dropped (a Rails array field posts a "" sentinel).
  def dirty_field_names
    raw = params.dig(:step, :dirty_fields)
    return nil unless raw.is_a?(Array)

    raw.map(&:to_s).compact_blank
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

  # Returns nil on success, or the message to refuse the response with. On
  # success the result is stashed in @sync_result so the stream/notice
  # decisions below can read whether TransitionSync skipped a stale row,
  # without sync_transitions itself growing any response-shaping logic.
  #
  # RecordNotUnique is two overlapping saves of the same newly minted row -
  # Turbo aborts the earlier fetch, not the server work behind it, so a
  # closing flush can still overlap an in-flight submit - and the loser hits
  # the unique index on transitions.uuid. Unlike RecordInvalid it carries no
  # #record, so the message reads straight off the exception.
  def sync_transitions(rename_pair)
    @sync_result = TransitionSync.call(@step, step_params[:transitions_json], renamed_variable: rename_pair)
    nil
  rescue TransitionSync::Malformed, ActiveRecord::RecordInvalid => e
    "This step was saved, but its connections were not: #{e.message}"
  rescue ActiveRecord::RecordNotUnique
    "This step was saved, but its connections were not: another save landed on the same connection " \
    "at the same moment. Reload and try again."
  end

  # True when this save's TransitionSync run skipped a rendered-but-gone row -
  # a connection this panel's snapshot claimed to have shown, but that had
  # already been deleted elsewhere. nil when transitions weren't synced at all.
  def healing_stale_panel?
    @sync_result&.skipped&.any? || false
  end

  def stale_panel_flash_stream
    flash.now[:notice] = STALE_PANEL_NOTICE
    turbo_stream.update("flash", partial: "shared/flash_messages")
  end

  def doors_changed?
    DOOR_DECIDING_PARAMS.any? { |key| step_params.key?(key) }
  end

  # True when this save changed the doors list in a way the editor's own
  # snapshot cannot show on its own - checked in both directions against the
  # transitions as saved (not as sent), since a rewritten condition is what
  # can make either one true:
  #
  # - forward: a row the editor was showing as an ordinary connection just
  #   became one of the doors Step::Doors now finds - it would otherwise
  #   render twice, once as a door and once still sitting in the editor below.
  # - backward: a door the editor was NOT showing (it wasn't a connection
  #   row - it was a door) just stopped being claimed and became an extra.
  #   Nothing about it is in the browser's `known` list, so a doors-only
  #   replace would leave it invisible even though the transition is still
  #   live in the database.
  #
  # `doors` is computed once by the caller and passed in, so this and the
  # forward check it used to make alone share one query.
  def door_shape_changed?(doors)
    sent_shown, sent_rows = shown_and_sent_row_uuids

    return true if doors.doors.filter_map(&:transition).any? { |t| sent_rows.include?(t.uuid) }

    doors.extras.any? { |t| sent_shown.exclude?(t.uuid) }
  end

  # [shown_uuids, row_uuids] from the transitions_json the browser just sent.
  # "Shown" is what the browser says this editor displayed: `rendered +
  # minted` under the current shape, or `known` under the legacy one - the
  # same either-shape read TransitionSync does, kept independent of it since
  # this runs whether or not a sync happened at all. No transitions_json, JSON
  # that doesn't parse, or a payload that is not the shape this page sends (an
  # Array, a scalar where a list belongs) "knows nothing" - each comes back as
  # empty arrays, same as #editor_row_became_door? used to treat them. A row
  # that is not an object is dropped, as TransitionSync#rows drops it.
  def shown_and_sent_row_uuids
    return [[], []] if step_params[:transitions_json].blank?

    payload = JSON.parse(step_params[:transitions_json])
    shown = if payload["rendered"].is_a?(Array) || payload["minted"].is_a?(Array)
              (payload["rendered"].to_a + payload["minted"].to_a).map(&:to_s)
            else
              payload["known"].to_a.map(&:to_s)
            end

    [shown, payload["rows"].to_a.grep(Hash).pluck("uuid")]
  rescue JSON::ParserError, NoMethodError, TypeError
    [[], []]
  end

  # The one place that decides which, if either, of the doors list and the
  # whole Connections fragment this save needs re-rendered. A rename always
  # needs the whole fragment - the editor's own snapshot still names the old
  # variable, and #door_shape_changed? cannot help with that since a renamed
  # condition does not change which uuids are doors. Otherwise, a save that
  # changed what decides the doors gets the doors list alone, unless the
  # doors list itself changed shape underneath the editor's snapshot.
  def connections_or_doors_stream(rename_pair)
    return full_connections_stream if rename_pair
    return nil unless doors_changed?

    door_shape_changed?(Step::Doors.for(@step.reload)) ? full_connections_stream : doors_stream
  end

  def full_connections_stream
    turbo_stream.update(dom_id(@step, :connections), partial: "steps/connections",
                                                     locals: { step: @step, workflow: @workflow, outline: outline })
  end

  def doors_stream
    turbo_stream.replace(dom_id(@step, :doors), partial: "steps/doors",
                                                locals: { step: @step, workflow: @workflow, outline: outline })
  end

  def broadcast_step_row(step)
    Turbo::StreamsChannel.broadcast_replace_to(
      "workflow_#{@workflow.id}",
      target: dom_id(step),
      partial: "workflows/step_row",
      locals: { step: step, workflow: @workflow, outline: outline }
    )
  end

  def step_json(step, notice: nil)
    {
      id: step.id,
      uuid: step.uuid,
      type: step.type.demodulize.underscore,
      title: step.title,
      position: step.position
    }.tap { |json| json[:notice] = notice if notice }
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
