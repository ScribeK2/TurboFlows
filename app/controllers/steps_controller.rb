class StepsController < ApplicationController
  include ActionView::RecordIdentifier

  before_action :set_workflow
  before_action :ensure_can_edit!
  before_action :set_step, only: %i[show edit update destroy reorder]

  # GET /workflows/:workflow_id/steps/:id
  def show
    respond_to do |format|
      format.html { render partial: "workflows/step_card", locals: { step: @step, workflow: @workflow } }
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
          partial: "workflows/step_card",
          locals: { step: @step, workflow: @workflow, expanded: true }
        )
      end
      format.html { render partial: "workflows/step_card", locals: { step: @step, workflow: @workflow, expanded: true } }
    end
  end

  # GET /workflows/:workflow_id/steps/:id/edit
  def edit
    render partial: "steps/edit_form", locals: { step: @step, workflow: @workflow },
           layout: false
  end

  # POST /workflows/:workflow_id/steps
  def create
    step_type = step_params[:type] || params[:step_type] || "action"
    step_class = step_class_for(step_type)
    position = @workflow.steps.maximum(:position).to_i + 1

    attrs = permitted_step_params.merge(workflow: @workflow, position: position)
    attrs[:title] = "Untitled #{step_type.titleize}" if attrs[:title].blank?

    @step = step_class.new(attrs)

    if @step.save
      ensure_start_step_assigned

      respond_to do |format|
        format.turbo_stream do
          streams = [
            turbo_stream.append("steps-list",
                                partial: "workflows/step_card",
                                locals: { step: @step, workflow: @workflow, expanded: true }),
            turbo_stream.remove("steps-empty-state")
          ]
          render turbo_stream: streams
        end
        format.html { redirect_to edit_workflow_path(@workflow), notice: "Step added." }
        format.json { render json: step_json(@step), status: :created }
      end

      broadcast_step_card(@step)
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.update("steps-list",
                                                   html: helpers.tag.div(@step.errors.full_messages.join(", "), class: "alert alert--warning mb-4")), status: :unprocessable_content
        end
        format.html { redirect_to edit_workflow_path(@workflow), alert: @step.errors.full_messages.join(", ") }
        format.json { render json: { errors: @step.errors.full_messages }, status: :unprocessable_content }
      end
    end
  end

  # PATCH /workflows/:workflow_id/steps/:id
  def update
    if @step.update(permitted_step_params)
      sync_transitions_from_json if step_params[:transitions_json].present?

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            dom_id(@step),
            partial: "workflows/step_card",
            locals: { step: @step.reload, workflow: @workflow }
          )
        end
        format.html { redirect_to edit_workflow_path(@workflow), notice: "Step updated." }
        format.json { render json: step_json(@step) }
      end

      broadcast_step_card(@step)
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            dom_id(@step, :form),
            partial: "steps/edit_form",
            locals: { step: @step, workflow: @workflow }
          ), status: :unprocessable_content
        end
        format.html { redirect_to edit_workflow_path(@workflow), alert: @step.errors.full_messages.join(", ") }
        format.json { render json: { errors: @step.errors.full_messages }, status: :unprocessable_content }
      end
    end
  end

  # DELETE /workflows/:workflow_id/steps/:id
  def destroy
    @step.destroy
    Step.rebalance_positions(@workflow)

    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.remove(dom_id(@step)) }
      format.html { redirect_to edit_workflow_path(@workflow), notice: "Step removed." }
      format.json { head :no_content }
    end

    Turbo::StreamsChannel.broadcast_remove_to(
      "workflow_#{@workflow.id}",
      target: dom_id(@step)
    )
  end

  # PATCH /workflows/:workflow_id/steps/:id/reorder
  def reorder
    StepReorderer.call(@workflow, @step, params[:position])

    # Broadcast updated list to all collaborators
    Turbo::StreamsChannel.broadcast_replace_to(
      "workflow_#{@workflow.id}",
      target: "steps-list",
      partial: "workflows/steps_list_items",
      locals: { workflow: @workflow.reload, steps: @workflow.steps.reload.includes(:transitions, :incoming_transitions) }
    )

    head :ok
  end

  private

  def set_workflow
    @workflow = Workflow.find(params[:workflow_id])
  end

  def set_step
    @step = @workflow.steps.unscoped.find(params[:id])
  end

  def ensure_can_edit!
    unless @workflow.can_be_edited_by?(current_user)
      redirect_to workflows_path, alert: "You don't have permission to edit this workflow."
    end
  end

  def step_params
    params.fetch(:step, {}).permit( # rubocop:disable Rails/StrongParametersExpect
      :type, :title, :question, :answer_type, :variable_name, :can_resolve,
      :action_type, :target_type, :target_value, :priority, :reason_required,
      :resolution_type, :resolution_code, :notes_required, :survey_trigger,
      :sub_flow_workflow_id, :instructions, :content, :notes, :lock_version,
      :transitions_json,
      options: [[:label, :value]],
      output_fields: [[:name, :value]],
      jumps: {},
      variable_mapping: {}
    )
  end

  def permitted_step_params
    step_params.except(:type, :transitions_json)
  end

  def step_class_for(type)
    case type.to_s
    when "question"  then Steps::Question
    when "action"    then Steps::Action
    when "message"   then Steps::Message
    when "escalate"  then Steps::Escalate
    when "resolve"   then Steps::Resolve
    when "sub_flow"  then Steps::SubFlow
    else Steps::Action
    end
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

    first_step = @workflow.steps.unscoped.where(workflow_id: @workflow.id).order(:position).first
    @workflow.update_column(:start_step_id, first_step.id) if first_step
  end

  def sync_transitions_from_json
    parsed = JSON.parse(step_params[:transitions_json])
    return unless parsed.is_a?(Array)

    steps_by_uuid = @workflow.steps.unscoped.where(workflow_id: @workflow.id).index_by(&:uuid)

    @step.transitions.destroy_all

    parsed.each_with_index do |t, pos|
      target_uuid = t["target_uuid"]
      next if target_uuid.blank?

      target = steps_by_uuid[target_uuid]
      next unless target

      Transition.create!(
        step: @step,
        target_step: target,
        condition: t["condition"].presence,
        label: t["label"].presence,
        position: pos
      )
    end
  rescue JSON::ParserError => e
    @step.errors.add(:base, "Invalid transitions JSON: #{e.message}")
  end

  def broadcast_step_card(step)
    Turbo::StreamsChannel.broadcast_replace_to(
      "workflow_#{@workflow.id}",
      target: dom_id(step),
      partial: "workflows/step_card",
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
end
