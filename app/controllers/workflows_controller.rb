class WorkflowsController < ApplicationController
  before_action :set_workflow,
                only: %i[show edit update destroy preview variables start begin_execution publish versions sync_steps flow_diagram settings add_tag remove_tag]
  before_action :ensure_editor_or_admin!, only: %i[new create]
  before_action :ensure_can_view_workflow!, only: %i[show start begin_execution preview variables versions flow_diagram settings]
  before_action :ensure_can_edit_workflow!, only: %i[edit update publish sync_steps]
  before_action :ensure_can_delete_workflow!, only: [:destroy]
  before_action :parse_transitions_json, only: %i[create update]

  def index
    filter = WorkflowsFilter.new(user: current_user, params: params).call

    @status_filter          = filter.status_filter
    @sort_by                = filter.sort_by
    @search_query           = filter.search_query
    @workflows              = filter.workflows
    @selected_group         = filter.selected_group
    @selected_ancestor_ids  = filter.selected_ancestor_ids
    @folders                = filter.folders
    @uncategorized_workflows = filter.uncategorized_workflows
    @workflows_by_folder    = filter.workflows_by_folder
    @accessible_groups      = filter.accessible_groups
    @total_count            = filter.total_count
    @total_pages            = filter.total_pages
    @page                   = filter.page
    @per_page               = WorkflowsFilter::PER_PAGE
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
    @workflow = current_user.workflows.build(
      status: 'draft',
      title: 'Untitled Workflow',
      graph_mode: true
    )
    # Save the draft immediately so the builder has a workflow ID for server-side
    # step rendering. Ensures the builder always has a persisted workflow to work with.
    if @workflow.save
      redirect_to workflow_path(@workflow, edit: true)
    else
      @accessible_groups = Group.visible_to(current_user).includes(:children).order(:name)
      render :new, status: :unprocessable_content
    end
  end

  def edit
    redirect_to workflow_path(@workflow, edit: true)
  end

  def create
    @workflow = current_user.workflows.build(workflow_params)

    if @workflow.save
      # Assign groups if provided
      if params[:workflow][:group_ids].present?
        group_ids = Array(params[:workflow][:group_ids]).reject(&:blank?).uniq
        group_ids.each_with_index do |group_id, index|
          @workflow.group_workflows.create!(
            group_id: group_id,
            is_primary: index == 0 # First group is primary
          )
        end
      end

      redirect_to @workflow, notice: "Workflow was successfully created."
    else
      # Eager load groups to prevent N+1 queries
      @accessible_groups = Group.visible_to(current_user).includes(:children).order(:name)
      render :new, status: :unprocessable_content
    end
  end

  def update
    # Get client's lock_version for optimistic locking
    client_lock_version = params[:workflow][:lock_version].to_i if params[:workflow][:lock_version].present?

    permitted_params = workflow_params

    # Steps are now persisted via sync_steps endpoint — remove step-related params
    permitted_params.delete(:visual_editor_steps_json)
    permitted_params.delete(:editor_mode)

    begin
      Workflow.transaction do
        # Check for version conflict if client sent a lock_version
        if client_lock_version.present? && client_lock_version > 0 && (@workflow.lock_version != client_lock_version)
          @workflow.errors.add(:base, "This workflow was modified by another user. Please refresh and try again.")
          raise ActiveRecord::StaleObjectError.new(@workflow, "update")
        end

        if @workflow.update(permitted_params)
          # Update group assignments
          if params[:workflow][:group_ids].present?
            @workflow.group_workflows.destroy_all
            group_ids = Array(params[:workflow][:group_ids]).reject(&:blank?).uniq
            group_ids.each_with_index do |group_id, index|
              @workflow.group_workflows.create!(
                group_id: group_id,
                is_primary: index == 0
              )
            end
          elsif params[:workflow].key?(:group_ids)
            # Explicitly clear groups if group_ids is present but empty
            @workflow.group_workflows.destroy_all
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
      @accessible_groups = Group.visible_to(current_user).includes(:children).order(:name)
      @selected_group_ids = @workflow.group_ids
      @conflict_detected = true
      flash.now[:alert] = "This workflow was modified by another user. Your changes could not be saved. Please review the current version and try again."
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "autosave-status",
            partial: "workflows/autosave_status",
            locals: { status: :error, errors: @workflow.errors }
          ), status: :unprocessable_content
        end
        format.json { render json: { status: "error", errors: @workflow.errors.full_messages }, status: :conflict }
        format.html { render :edit, status: :conflict }
      end
      return
    end

    # Handle validation errors (when update returns false)
    unless performed?
      @accessible_groups = Group.visible_to(current_user).order(:name)
      @selected_group_ids = @workflow.group_ids
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "autosave-status",
            partial: "workflows/autosave_status",
            locals: { status: :error, errors: @workflow.errors }
          ), status: :unprocessable_content
        end
        format.json { render json: { status: "error", errors: @workflow.errors.full_messages }, status: :unprocessable_content }
        format.html { render :edit, status: :unprocessable_content }
      end
    end
  end

  def sync_steps
    client_lock_version = params[:lock_version].to_i

    if client_lock_version > 0 && @workflow.lock_version != client_lock_version
      render json: { error: "This workflow was modified by another user. Please refresh and try again." },
             status: :conflict
      return
    end

    result = StepSyncer.call(
      @workflow,
      params[:steps] || [],
      start_node_uuid: params[:start_node_uuid],
      title: params[:title].presence,
      description: params.key?(:description) ? params[:description] : nil
    )

    if result.success?
      render json: { success: true, lock_version: result.lock_version }
    else
      render json: { error: result.error }, status: :unprocessable_content
    end
  end

  def destroy
    @workflow.destroy
    redirect_to workflows_path, notice: "Workflow was successfully deleted."
  end

  def preview
    # Parse step data from params
    step_data = parse_step_from_params
    step_index = params[:step_index].to_i

    # Generate sample variables for interpolation preview
    # This allows users to see what variables will look like when interpolated
    sample_variables = generate_sample_variables(@workflow)

    # Render preview partial wrapped in matching Turbo Frame for src-driven updates
    render partial: "workflows/preview_frame",
           locals: { step: step_data, index: step_index, sample_variables: sample_variables },
           formats: [:html]
  end

  def variables
    # Return available variables from workflow
    variables = @workflow.variables

    render json: { variables: variables }
  end

  def start
    # Shows landing page for starting workflow
  end

  def begin_execution
    # Create scenario and start workflow execution
    @scenario = Scenario.new(
      workflow: @workflow,
      user: current_user,
      current_step_index: 0,
      current_node_uuid: @workflow.start_node&.uuid,
      execution_path: [],
      results: {},
      inputs: {},
      status: 'active'
    )

    if @scenario.save
      redirect_to step_scenario_path(@scenario), notice: "Workflow started!"
    else
      redirect_to start_workflow_path(@workflow), alert: "Failed to start workflow: #{@scenario.errors.full_messages.join(', ')}"
    end
  end

  def publish
    result = WorkflowPublisher.publish(@workflow, current_user, changelog: params[:changelog])

    if result.success?
      redirect_to @workflow, notice: "Workflow published as version #{result.version.version_number}."
    else
      redirect_to @workflow, alert: "Failed to publish: #{result.error}"
    end
  end

  def versions
    @versions = @workflow.versions.newest_first.includes(:published_by)
  end

  # GET /workflows/:id/flow_diagram
  def flow_diagram
    eager_load_steps
    levels = FlowDiagramService.call(@workflow)
    render partial: "workflows/flow_diagram_panel",
           locals: { workflow: @workflow, levels: levels },
           layout: false
  end

  # GET /workflows/:id/settings
  def settings
    @accessible_groups = Group.visible_to(current_user).includes(:children).order(:name)
    readonly = !@workflow.can_be_edited_by?(current_user)
    render partial: "workflows/settings_panel",
           locals: { workflow: @workflow, readonly: readonly, accessible_groups: @accessible_groups },
           layout: false
  end

  def add_tag
    return head(:forbidden) unless current_user.can_manage_tags?

    tag = Tag.find(params[:tag_id])
    @workflow.tags << tag unless @workflow.tags.include?(tag)
    render turbo_stream: turbo_stream.replace("workflow-tags", partial: "tags/tag_selector", locals: { workflow: @workflow })
  end

  def remove_tag
    return head(:forbidden) unless current_user.can_manage_tags?

    tag = Tag.find(params[:tag_id])
    @workflow.tags.delete(tag)
    render turbo_stream: turbo_stream.replace("workflow-tags", partial: "tags/tag_selector", locals: { workflow: @workflow })
  end

  def generate_share
    @workflow = Workflow.find(params[:id])
    return head(:forbidden) unless @workflow.can_be_edited_by?(current_user)

    @workflow.generate_share_token!
    redirect_to @workflow, notice: "Share link generated."
  end

  def revoke_share
    @workflow = Workflow.find(params[:id])
    return head(:forbidden) unless @workflow.can_be_edited_by?(current_user)

    @workflow.revoke_share_token!
    redirect_to @workflow, notice: "Share link revoked."
  end

  private

  # Generate sample variable values for preview interpolation
  # This creates realistic sample data so users can see what interpolated text looks like
  def generate_sample_variables(workflow)
    return {} unless workflow&.steps&.any?

    sample_vars = {}

    workflow.steps.each do |step|
      # Get variables from question steps
      if step.is_a?(Steps::Question) && step.variable_name.present?
        sample_vars[step.variable_name] = case step.answer_type
                                          when 'yes_no'
                                            'yes'
                                          when 'number'
                                            '42'
                                          when 'date'
                                            Date.today.strftime('%Y-%m-%d')
                                          when 'multiple_choice', 'dropdown'
                                            opts = step.options
                                            if opts.present? && opts.is_a?(Array) && opts.first
                                              opt = opts.first
                                              opt.is_a?(Hash) ? (opt['value'] || opt['label'] || 'option1') : opt.to_s
                                            else
                                              'option1'
                                            end
                                          else
                                            step.title.present? ? step.title.split(' ').first : 'sample_value'
                                          end
      end

      # Get variables from action step output_fields
      next unless step.is_a?(Steps::Action) && step.output_fields.present? && step.output_fields.is_a?(Array)

      step.output_fields.each do |output_field|
        next unless output_field.is_a?(Hash) && output_field['name'].present?

        var_name = output_field['name']
        sample_vars[var_name] = if output_field['value'].present?
                                  output_field['value'].include?('{{') ? '[interpolated]' : output_field['value']
                                else
                                  'completed'
                                end
      end
    end

    sample_vars
  end

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

  # All workflows are graph mode — linear mode is no longer supported
  def determine_graph_mode_for_new
    true
  end

  # Override parent methods to use @workflow instance variable
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
    params.require(:workflow).permit(:title, :description, :is_public, :lock_version,
                                     :graph_mode, :embed_enabled,
                                     :visual_editor_steps_json, :editor_mode)
  end

  def parse_step_from_params
    step_params = params[:step] || {}

    # Parse options if provided as JSON string or array
    options = step_params[:options]
    if options.is_a?(String)
      begin
        options = JSON.parse(options)
      rescue JSON::ParserError
        options = []
      end
    elsif options.is_a?(Array)
      # Options is already an array, process it
      options = options.map do |opt|
        if opt.is_a?(Hash)
          { 'label' => opt['label'] || opt[:label], 'value' => opt['value'] || opt[:value] }
        else
          { 'label' => opt.to_s, 'value' => opt.to_s }
        end
      end
    elsif options.is_a?(ActionController::Parameters)
      # Handle Rails strong parameters
      options = options.values.map do |opt|
        { 'label' => opt['label'] || opt[:label], 'value' => opt['value'] || opt[:value] }
      end
    else
      options = []
    end

    # Parse attachments if provided
    attachments = step_params[:attachments]
    if attachments.is_a?(String)
      begin
        attachments = JSON.parse(attachments)
      rescue JSON::ParserError
        attachments = []
      end
    elsif attachments.is_a?(Array)
      attachments = attachments.compact
    else
      attachments = []
    end

    {
      "type" => step_params[:type] || "",
      "title" => step_params[:title] || "",
      "description" => step_params[:description] || "",
      # Question fields
      "question" => step_params[:question] || "",
      "answer_type" => step_params[:answer_type] || "",
      "variable_name" => step_params[:variable_name] || "",
      "options" => options || [],
      # Decision fields
      "condition" => step_params[:condition] || "",
      "true_path" => step_params[:true_path] || "",
      "false_path" => step_params[:false_path] || "",
      # Action fields
      "action_type" => step_params[:action_type] || "",
      "instructions" => step_params[:instructions] || "",
      "attachments" => attachments || [],
      # Message fields
      "content" => step_params[:content] || "",
      # Escalate fields
      "target_type" => step_params[:target_type] || "",
      "target_value" => step_params[:target_value] || "",
      "priority" => step_params[:priority] || "",
      "reason_required" => step_params[:reason_required] || "",
      "notes" => step_params[:notes] || "",
      # Resolve fields
      "resolution_type" => step_params[:resolution_type] || "",
      "resolution_code" => step_params[:resolution_code] || "",
      "notes_required" => step_params[:notes_required] || "",
      "survey_trigger" => step_params[:survey_trigger] || "",
      # Sub-flow fields
      "target_workflow_id" => step_params[:target_workflow_id] || ""
    }
  end

  # Parse transitions_json from form submissions into proper transitions array
  # The frontend sends transitions and output_fields as JSON strings,
  # but strong params expects them as nested array structures.
  # This before_action converts the JSON strings to the expected format.
  def parse_transitions_json
    return unless params[:workflow]&.dig(:steps).present?

    Rails.logger.info "[parse_transitions_json] Processing #{params[:workflow][:steps].length} steps"

    params[:workflow][:steps].each_with_index do |step, index|
      next unless step.is_a?(ActionController::Parameters) || step.is_a?(Hash)

      Rails.logger.info "[parse_transitions_json] Step #{index}: transitions_json=#{step[:transitions_json].inspect}"

      # Parse transitions_json to transitions array
      if step[:transitions_json].present?
        begin
          parsed = JSON.parse(step[:transitions_json])
          step[:transitions] = parsed if parsed.is_a?(Array)
          Rails.logger.info "[parse_transitions_json] Step #{index}: parsed #{parsed.length} transitions"
        rescue JSON::ParserError => e
          Rails.logger.error "[parse_transitions_json] Step #{index}: JSON parse error: #{e.message}"
          flash[:alert] = "Invalid transitions JSON in step #{index + 1}: #{e.message}"
          step[:transitions] = []
        end
        step.delete(:transitions_json)
      else
        Rails.logger.info "[parse_transitions_json] Step #{index}: NO transitions_json field"
      end

      # Parse attachments if it's a JSON string
      if step[:attachments].is_a?(String)
        begin
          parsed = JSON.parse(step[:attachments])
          step[:attachments] = parsed if parsed.is_a?(Array)
        rescue JSON::ParserError
          step[:attachments] = []
        end
      end

      # Parse output_fields if it's a JSON string
      next unless step[:output_fields].is_a?(String)

      begin
        parsed = JSON.parse(step[:output_fields])
        step[:output_fields] = parsed if parsed.is_a?(Array)
      rescue JSON::ParserError
        step[:output_fields] = []
      end
    end
  end
end
