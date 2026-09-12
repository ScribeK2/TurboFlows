class WorkflowsController < ApplicationController
  before_action :ensure_can_manage_workflows!
  before_action :set_workflow, only: %i[show edit update destroy]
  before_action :ensure_editor_or_admin!, only: %i[new create]
  before_action :ensure_can_view_workflow!, only: %i[show]
  before_action :ensure_can_edit_workflow!, only: %i[edit update]
  before_action :ensure_can_delete_workflow!, only: [:destroy]
  before_action :parse_transitions_json, only: %i[create update]

  def index
    filter = WorkflowsFilter.new(user: current_user, params: params).call

    @status_filter          = filter.status_filter
    @sort_by                = filter.sort_by
    @search_query           = filter.search_query
    @audience_filter        = filter.audience_filter
    @owner_filter           = filter.owner_filter
    @workflows              = filter.workflows
    @selected_group         = filter.selected_group
    @selected_ancestor_ids  = filter.selected_ancestor_ids
    @folders                = filter.folders
    @unfiled_workflows      = filter.unfiled_workflows
    @linkable_group_ids     = filter.linkable_group_ids
    @workflows_by_folder    = filter.workflows_by_folder
    @accessible_groups      = filter.accessible_groups
    @total_count            = filter.total_count
    @total_pages            = filter.total_pages
    @page                   = filter.page
    @per_page               = filter.per_page_size
    @workflows_paginated    = filter.workflows_paginated

    flash.now[:alert] = filter.group_error if filter.group_error

    respond_to do |format|
      format.html
      format.json do
        workflows_data = @workflows.map do |w|
          {
            id: w.id,
            title: w.title,
            description: w.description_text&.truncate(100),
            status: w.status,
            graph_mode: true,
            step_count: w.steps.size
          }
        end
        render json: workflows_data
      end
    end
  end

  def show
    eager_load_steps
    preload_subflow_targets

    @steps = @workflow.steps.includes(:transitions, :incoming_transitions).order(:position)
    @mode = if params[:edit].present? && @workflow.can_be_edited_by?(current_user)
              "edit"
            else
              "view"
            end
  end

  def new
    existing = Workflow.find_reusable_draft_for(current_user)
    if existing
      redirect_to workflow_path(existing, edit: true)
    else
      redirect_to workflows_path
    end
  end

  def edit
    redirect_to workflow_path(@workflow, edit: true)
  end

  def create
    if params[:workflow].blank?
      @workflow = Workflow.find_or_create_draft_for(current_user)
      redirect_to workflow_path(@workflow, edit: true)
      return
    end

    @workflow = current_user.workflows.build(workflow_params)

    if @workflow.save
      if params[:workflow][:group_ids].present?
        @workflow.replace_groups!(Group.assignable_ids_for(current_user, params[:workflow][:group_ids], current_ids: []))
      end

      redirect_to @workflow, notice: "Workflow was successfully created."
    else
      redirect_to workflows_path, alert: "Workflow couldn't be created: #{@workflow.errors.full_messages.to_sentence}."
    end
  end

  def update
    # Get client's lock_version for optimistic locking
    client_lock_version = params[:workflow][:lock_version].to_i if params[:workflow][:lock_version].present?

    permitted_params = workflow_params

    begin
      Workflow.transaction do
        # Check for version conflict if client sent a lock_version
        if client_lock_version.present? && client_lock_version.positive? && (@workflow.lock_version != client_lock_version)
          @workflow.errors.add(:base, "This workflow was modified by another user. Please refresh and try again.")
          raise ActiveRecord::StaleObjectError.new(@workflow, "update")
        end

        if @workflow.update(permitted_params)
          # The Details form always sends group_ids (a blank sentinel first), so
          # a key with nothing ticked means "no groups", not "not submitted".
          if params[:workflow].key?(:group_ids)
            @workflow.replace_groups!(
              Group.assignable_ids_for(current_user, params[:workflow][:group_ids], current_ids: @workflow.group_ids)
            )
          end

          respond_to do |format|
            format.turbo_stream do
              render turbo_stream: turbo_stream.replace(
                "autosave-status",
                partial: "workflows/autosave_status",
                locals: { status: :saved }
              )
            end
            format.json { render json: { status: "saved", title: @workflow.title } }
            format.html { redirect_to @workflow, notice: "Workflow was successfully updated." }
          end
        else
          raise ActiveRecord::Rollback
        end
      end
    rescue ActiveRecord::StaleObjectError
      @workflow.reload
      @conflict_detected = true
      flash.now[:alert] = "This workflow was modified by another user. Your changes could not be saved. Please review the current version and try again."
      render_update_error(status: :conflict)
      return
    end

    # Handle validation errors (when update returns false)
    render_update_error(status: :unprocessable_content) unless performed?
  end

  def destroy
    @workflow.destroy
    redirect_to workflows_path, notice: "Workflow was successfully deleted."
  end

  private

  def set_workflow
    @workflow = Workflow.find(params[:id])
  end

  # Eager load steps with rich text associations and transitions to prevent N+1 queries.
  # Rich text associations are defined on specific STI subclasses, so we preload per-type.
  def eager_load_steps
    steps = @workflow.steps.includes(transitions: :target_step).to_a

    { rich_text_instructions: Steps::Action,
      rich_text_content: Steps::Message,
      rich_text_notes: Steps::Escalate }.each do |assoc, klass|
      typed = steps.grep(klass)
      next if typed.empty?

      ActiveRecord::Associations::Preloader.new(records: typed, associations: [assoc]).call
    end
  end

  # Preload all workflows referenced by sub-flow steps to avoid N+1 queries in partials
  def preload_subflow_targets
    subflow_ids = Steps::SubFlow.where(workflow_id: @workflow.id).pluck(:sub_flow_workflow_id).compact
    @subflow_targets = Workflow.where(id: subflow_ids).index_by(&:id) if subflow_ids.any?
  end

  def render_update_error(status:)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "autosave-status",
          partial: "workflows/autosave_status",
          locals: { status: :error, errors: @workflow.errors }
        ), status: status
      end
      format.json { render json: { status: "error", errors: @workflow.errors.full_messages }, status: status }
      format.html do
        alert = @conflict_detected ? flash.now[:alert] : "Couldn't save: #{@workflow.errors.full_messages.to_sentence}."
        redirect_to workflow_path(@workflow, edit: true), alert:, status: :see_other
      end
    end
  end

  def ensure_can_view_workflow!
    unless @workflow.can_be_viewed_by?(current_user)
      redirect_to workflows_path, alert: "You don't have permission to view this workflow."
    end
  end

  def ensure_can_edit_workflow!
    unless @workflow.can_be_edited_by?(current_user)
      redirect_to workflows_path, alert: "You don't have permission to edit this workflow."
    end
  end

  def ensure_can_delete_workflow!
    unless @workflow.can_be_deleted_by?(current_user)
      redirect_to workflows_path, alert: "You don't have permission to delete this workflow."
    end
  end

  def workflow_params
    # lock_version is used for optimistic locking to prevent race conditions
    # graph_mode is for DAG-based workflows
    # Steps are managed via AR Step records, not workflow params
    params.expect(workflow: %i[title description lock_version graph_mode embed_enabled])
  end

  # Parse transitions_json from form submissions into proper transitions array.
  # Delegates to StepParamsForm for each step, replacing JSON string fields
  # (transitions_json, output_fields, attachments) with parsed Ruby arrays.
  # See app/forms/step_params_form.rb — addresses audit finding C-02 (High).
  def parse_transitions_json
    return if params[:workflow]&.dig(:steps).blank?

    Rails.logger.debug { "[parse_transitions_json] Processing #{params[:workflow][:steps].length} steps" }

    params[:workflow][:steps].each_with_index do |step, index|
      next unless step.is_a?(ActionController::Parameters) || step.is_a?(Hash)

      Rails.logger.debug { "[parse_transitions_json] Step #{index}: transitions_json=#{step[:transitions_json].inspect}" }

      form = StepParamsForm.new(step)
      parsed_params = form.to_step_params

      step[:transitions]   = parsed_params[:transitions]
      step[:output_fields] = parsed_params[:output_fields]
      step[:attachments]   = parsed_params[:attachments]
      step.delete(:transitions_json)

      Rails.logger.debug { "[parse_transitions_json] Step #{index}: parsed #{form.transitions.length} transitions" }
    end
  end
end
