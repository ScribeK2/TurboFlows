class StepsController < ApplicationController
  before_action :set_workflow
  before_action :ensure_can_edit!
  before_action :set_step, only: %i[show edit update destroy reorder]

  # GET /workflows/:workflow_id/steps/:id
  def show
    respond_to do |format|
      format.html { render partial: "workflows/step_item", locals: step_locals(@step) }
      format.json { render json: step_json(@step) }
    end
  end

  # GET /workflows/:workflow_id/steps/new
  def new
    step_type = params[:step_type] || "action"
    step_class = step_class_for(step_type)
    position = @workflow.workflow_steps.maximum(:position).to_i + 1

    @step = step_class.new(workflow: @workflow, position: position, title: "")

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "steps-list",
          partial: "workflows/step_item",
          locals: step_locals(@step, expanded: true)
        )
      end
      format.html { render partial: "workflows/step_item", locals: step_locals(@step, expanded: true) }
    end
  end

  # POST /workflows/:workflow_id/steps
  def create
    step_type = step_params[:type] || params[:step_type] || "action"
    step_class = step_class_for(step_type)
    position = @workflow.workflow_steps.maximum(:position).to_i + 1

    @step = step_class.new(permitted_step_params.merge(workflow: @workflow, position: position))

    if @step.save
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.append(
            "steps-list",
            partial: "workflows/step_item",
            locals: step_locals(@step)
          )
        end
        format.html { redirect_to edit_workflow_path(@workflow), notice: "Step added." }
        format.json { render json: step_json(@step), status: :created }
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "new-step-form",
            partial: "workflows/step_form",
            locals: { step: @step, workflow: @workflow }
          ), status: :unprocessable_content
        end
        format.html { redirect_to edit_workflow_path(@workflow), alert: @step.errors.full_messages.join(", ") }
        format.json { render json: { errors: @step.errors.full_messages }, status: :unprocessable_content }
      end
    end
  end

  # PATCH /workflows/:workflow_id/steps/:id
  def update
    if @step.update(permitted_step_params)
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            dom_id(@step),
            partial: "workflows/step_item",
            locals: step_locals(@step)
          )
        end
        format.html { redirect_to edit_workflow_path(@workflow), notice: "Step updated." }
        format.json { render json: step_json(@step) }
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            dom_id(@step),
            partial: "workflows/step_item",
            locals: step_locals(@step, expanded: true)
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

    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.remove(dom_id(@step)) }
      format.html { redirect_to edit_workflow_path(@workflow), notice: "Step removed." }
      format.json { head :no_content }
    end
  end

  # PATCH /workflows/:workflow_id/steps/:id/reorder
  def reorder
    new_position = params[:position].to_i

    Step.transaction do
      @step.update!(position: new_position)
      # Reindex siblings to prevent gaps
      @workflow.workflow_steps.unscoped
        .where(workflow_id: @workflow.id)
        .where.not(id: @step.id)
        .order(:position)
        .each_with_index do |sibling, idx|
          adjusted = idx >= new_position ? idx + 1 : idx
          sibling.update_column(:position, adjusted) if sibling.position != adjusted
        end
    end

    respond_to do |format|
      format.turbo_stream { head :ok }
      format.json { render json: { position: @step.position } }
    end
  end

  private

  def set_workflow
    @workflow = Workflow.find(params[:workflow_id])
  end

  def set_step
    @step = @workflow.workflow_steps.unscoped.find(params[:id])
  end

  def ensure_can_edit!
    unless @workflow.can_be_edited_by?(current_user)
      redirect_to workflows_path, alert: "You don't have permission to edit this workflow."
    end
  end

  def step_params
    params.require(:step).permit(
      :type, :title, :question, :answer_type, :variable_name, :can_resolve,
      :action_type, :target_type, :target_value, :priority, :reason_required,
      :resolution_type, :resolution_code, :notes_required, :survey_trigger,
      :sub_flow_workflow_id, :instructions, :content, :notes,
      options: {},
      output_fields: {},
      jumps: {},
      variable_mapping: {}
    )
  end

  def permitted_step_params
    step_params.except(:type)
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
