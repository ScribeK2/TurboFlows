class WorkflowsController < ApplicationController
  before_action :set_workflow,
                only: %i[show edit update destroy export export_pdf preview variables save_as_template start begin_execution step1 update_step1 step2 update_step2 step3 create_from_draft render_step publish versions sync_steps flow_diagram settings]
  before_action :ensure_draft_workflow!, only: %i[step1 update_step1 step2 update_step2 step3 create_from_draft]
  before_action :ensure_editor_or_admin!, only: %i[new create import import_file start_wizard]
  before_action :ensure_can_view_workflow!, only: %i[show export export_pdf start begin_execution preview variables versions flow_diagram settings]
  before_action :ensure_can_edit_workflow!, only: %i[edit update save_as_template publish render_step sync_steps]
  before_action :ensure_can_delete_workflow!, only: [:destroy]
  before_action :parse_transitions_json, only: %i[create update update_step2]

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
    # step rendering. This mirrors start_wizard and ensures addStepFromModal never
    # falls back to client-side rendering on a truly unsaved record.
    if @workflow.save
      redirect_to workflow_path(@workflow, edit: true)
    else
      @accessible_groups = Group.visible_to(current_user).includes(:children).order(:name)
      render :new, status: :unprocessable_content
    end
  end

  def start_wizard
    @workflow = current_user.workflows.build(
      status: 'draft',
      title: 'Untitled Workflow',
      graph_mode: true
    )
    if @workflow.save
      redirect_to step1_workflow_path(@workflow), notice: "Let's create your workflow step by step."
    else
      redirect_to workflows_path, alert: "Could not start wizard. Please try again."
    end
  end

  def edit
    # Eager load groups to prevent N+1 queries
    @accessible_groups = Group.visible_to(current_user).includes(:children).order(:name)
    @selected_group_ids = @workflow.group_ids
    eager_load_steps
    preload_subflow_targets
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

          redirect_to @workflow, notice: "Workflow was successfully updated."
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
      render :edit, status: :conflict
      return
    end

    # Handle validation errors (when update returns false)
    unless performed?
      @accessible_groups = Group.visible_to(current_user).order(:name)
      @selected_group_ids = @workflow.group_ids
      render :edit, status: :unprocessable_content
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

  def export
    # Build comprehensive export data including Graph Mode fields
    # Use AR steps if available, otherwise fall back to JSONB
    steps_data = serialize_ar_steps_for_export(@workflow)
    start_uuid = @workflow.start_step&.uuid || @workflow.steps.first&.uuid

    export_data = {
      title: @workflow.title,
      description: @workflow.description_text || "",
      graph_mode: true,
      start_node_uuid: start_uuid,
      steps: steps_data,
      exported_at: Time.current.iso8601,
      export_version: "2.0"
    }

    send_data export_data.to_json,
              filename: "#{@workflow.title.parameterize}.json",
              type: "application/json"
  end

  def export_pdf
    require "prawn"

    pdf = Prawn::Document.new
    pdf.text @workflow.title, size: 24, style: :bold
    pdf.move_down 10
    pdf.text @workflow.description_text, size: 12 if @workflow.description_text.present?
    pdf.move_down 10

    pdf.text "Mode: Graph Mode", size: 10, style: :italic
    pdf.move_down 20

    export_pdf_ar_steps(pdf) if @workflow.steps.any?

    send_data pdf.render, filename: "#{@workflow.title.parameterize}.pdf", type: "application/pdf"
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

  # Sprint 3: Render step HTML for dynamic step creation
  # Supports both legacy JSONB mode and new ActiveRecord Step mode.
  # When workflow has AR steps (steps.any?), creates an AR Step record.
  # Otherwise falls back to building a JSONB hash for backward compatibility.
  def render_step
    Rails.logger.debug { "[render_step] Params: #{params.inspect}" }

    step_type = params[:step_type]
    step_index = params[:step_index].to_i

    # Convert step_data to hash with indifferent access
    raw_step_data = params[:step_data]
    step_data = if raw_step_data.is_a?(ActionController::Parameters)
                  raw_step_data.to_unsafe_h.with_indifferent_access
                elsif raw_step_data.is_a?(Hash)
                  raw_step_data.with_indifferent_access
                else
                  {}.with_indifferent_access
                end

    Rails.logger.debug { "[render_step] step_type=#{step_type}, step_index=#{step_index}, step_data=#{step_data.inspect}" }

    step_class = StepBuilder.sti_class_for(step_type)
    position = @workflow.steps.maximum(:position).to_i + 1
    attrs = { workflow: @workflow, position: position, title: step_data[:title] || "" }

    case step_type
    when "question"
      attrs[:question] = step_data[:question] || ""
      attrs[:answer_type] = step_data[:answer_type] || "yes_no"
      attrs[:variable_name] = step_data[:variable_name] || ""
    when "action"
      attrs[:action_type] = step_data[:action_type] || "Instruction"
    when "sub_flow"
      attrs[:sub_flow_workflow_id] = step_data[:target_workflow_id] if step_data[:target_workflow_id].present?
    end

    step = step_class.new(attrs)
    step.uuid ||= SecureRandom.uuid # Ensure UUID is set (before_validation is skipped below)
    step.save!(validate: false) # Skip validations — placeholder step, user fills in details via form

    # Set rich text after save
    case step_type
    when "action"
      step.update(instructions: step_data[:instructions]) if step_data[:instructions].present?
    when "message"
      step.update(content: step_data[:content]) if step_data[:content].present?
    when "escalate"
      step.update(notes: step_data[:notes]) if step_data[:notes].present?
    end

    begin
      render partial: "workflows/step_card",
             locals: { step: step, workflow: @workflow, expanded: true },
             formats: [:html]
    rescue StandardError => e
      Rails.logger.error "[render_step] Error rendering step: #{e.message}"
      render plain: "Error rendering step: #{e.message}", status: :internal_server_error
    end
  end

  def save_as_template
    template_params = params.require(:template).permit(:name, :category, :description, :is_public)

    template_data = @workflow.convert_to_template(
      name: template_params[:name],
      category: template_params[:category],
      description: template_params[:description],
      is_public: template_params[:is_public] == "true"
    )

    @template = Template.new(template_data)

    if @template.save
      redirect_to templates_path, notice: "Template '#{@template.name}' was successfully created."
    else
      redirect_to edit_workflow_path(@workflow), alert: "Failed to save template: #{@template.errors.full_messages.join(', ')}"
    end
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

  def import
    # Show import form
  end

  def import_file
    unless params[:file].present?
      redirect_to import_workflows_path, alert: "Please select a file to import."
      return
    end

    uploaded_file = params[:file]
    file_content = uploaded_file.read.force_encoding("UTF-8")

    # Validate file size (max 10MB)
    if file_content.bytesize > 10.megabytes
      redirect_to import_workflows_path, alert: "File is too large. Maximum size is 10MB."
      return
    end

    # Detect file format from filename/content_type
    format = detect_file_format(uploaded_file.original_filename, uploaded_file.content_type)

    unless format
      redirect_to import_workflows_path, alert: "Unsupported file format. Please use JSON, CSV, YAML, or Markdown files."
      return
    end

    result = WorkflowImporter.new(current_user, format: format, content: file_content).call

    if result.success?
      @workflow = result.workflow

      if result.incomplete_steps? || result.warnings.any?
        notice_parts = ["Workflow imported successfully in Graph Mode!"]
        notice_parts << "#{result.incomplete_steps_count} incomplete step(s) need attention." if result.incomplete_steps?
        notice_parts << "#{result.warnings.count} warning(s) occurred." if result.warnings.any?
        redirect_to edit_workflow_path(@workflow), notice: notice_parts.join(" ")
      else
        redirect_to @workflow, notice: "Workflow imported successfully in Graph Mode!"
      end
    else
      error_summary = truncate_for_flash(result.errors, max_items: 3)
      redirect_to import_workflows_path, alert: "Failed to import workflow: #{error_summary}"
    end
  end

  # Wizard step actions
  def step1
    # Load draft workflow and accessible groups
    @accessible_groups = Group.visible_to(current_user).includes(:children).order(:name)
    @selected_group_ids = @workflow.group_ids
  end

  def update_step1
    if @workflow.update(workflow_step1_params)
      # Update group assignments
      if params[:workflow][:group_ids].present?
        @workflow.group_workflows.destroy_all
        # Deduplicate group_ids to prevent duplicate entries
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

      # Assign folder if provided
      if params[:workflow][:folder_id].present? && params[:workflow][:group_ids].present?
        primary_group_id = Array(params[:workflow][:group_ids]).reject(&:blank?).first
        primary_gw = @workflow.group_workflows.find_by(group_id: primary_group_id)
        if primary_gw
          folder = Folder.find_by(id: params[:workflow][:folder_id], group_id: primary_group_id)
          primary_gw.update!(folder: folder) if folder
        end
      end

      redirect_to step2_workflow_path(@workflow), notice: "Step 1 completed. Now let's add some steps."
    else
      @accessible_groups = Group.visible_to(current_user).includes(:children).order(:name)
      @selected_group_ids = @workflow.group_ids
      render :step1, status: :unprocessable_content
    end
  end

  def step2
    # Load draft workflow for step 2 (add steps)
    # Steps will be managed via the existing workflow-builder controller
    eager_load_steps
  end

  def update_step2
    # Parse incoming steps from visual editor or list editor
    incoming_steps = nil
    start_uuid = nil

    if params[:workflow][:editor_mode] == 'visual' && params[:workflow][:visual_editor_steps_json].present?
      begin
        incoming_steps = JSON.parse(params[:workflow][:visual_editor_steps_json])
        start_uuid = params[:workflow][:start_node_uuid]
      rescue JSON::ParserError => e
        Rails.logger.error "[update_step2] Failed to parse visual editor steps: #{e.message}"
        flash[:alert] = "Failed to save visual editor changes."
        redirect_to step2_workflow_path(@workflow) and return
      end
    else
      permitted_params = workflow_step2_params
      incoming_steps = permitted_params[:steps]&.map { |s| s.respond_to?(:to_h) ? s.to_h : s }
    end

    if incoming_steps.present?
      begin
        create_ar_steps_from_params(incoming_steps, start_uuid)
        redirect_to step3_workflow_path(@workflow), notice: "Steps added. Let's review your workflow."
      rescue ActiveRecord::RecordInvalid => e
        @workflow.errors.add(:base, e.message)
        render :step2, status: :unprocessable_content
      end
    else
      redirect_to step3_workflow_path(@workflow), notice: "Steps added. Let's review your workflow."
    end
  end

  def step3
    # Load draft workflow for step 3 (review and launch)
    # Preview will be shown here
    eager_load_steps
  end

  def create_from_draft
    # Save as Draft: skip publish logic, redirect with confirmation
    if params[:save_draft].present?
      flash[:notice] = "Draft saved."
      redirect_to step3_workflow_path(@workflow)
      return
    end

    # Validate draft before converting to published
    unless @workflow.valid?
      render :step3, status: :unprocessable_content
      return
    end

    # Validate that workflow has at least one step
    unless @workflow.steps.any?
      @workflow.errors.add(:base, "Workflow must have at least one step")
      render :step3, status: :unprocessable_content
      return
    end

    # Validate all steps have required fields
    @workflow.steps.order(:position).each do |step|
      unless step.title.present?
        @workflow.errors.add(:steps, "Step #{step.position + 1}: Step title is required")
      end

      if step.is_a?(Steps::Question) && !step.question.present?
        @workflow.errors.add(:steps, "Step #{step.position + 1}: Question text is required for question steps")
      end
    end

    if @workflow.errors.any?
      render :step3, status: :unprocessable_content
      return
    end

    # Convert draft to published workflow
    @workflow.status = 'published'
    @workflow.draft_expires_at = nil

    # Assign to Uncategorized group if no groups assigned (triggered by status change)
    if @workflow.save
      # Ensure groups are assigned (after_create callback handles this for published workflows)
      @workflow.assign_to_uncategorized_if_needed if @workflow.groups.empty?

      redirect_to @workflow, notice: "Workflow was successfully created!"
    else
      render :step3, status: :unprocessable_content
    end
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

  # Create AR steps from incoming params (used by update_step2 wizard flow)
  def create_ar_steps_from_params(incoming_steps, start_uuid = nil)
    normalized = incoming_steps.map do |s|
      s = s.to_h if s.respond_to?(:to_h) && !s.is_a?(Hash)
      s.stringify_keys
    end
    StepBuilder.call(@workflow, normalized, start_node_uuid: start_uuid, replace: true)
  end

  # Serialize AR steps to JSONB-compatible format for export
  def serialize_ar_steps_for_export(workflow)
    StepSerializer.call(workflow)
  end

  # PDF export for AR steps
  def export_pdf_ar_steps(pdf)
    @workflow.steps.includes(:transitions).each_with_index do |step, index|
      step_type = step.type.demodulize.capitalize
      pdf.text "#{index + 1}. #{step.title} [#{step_type}]", size: 14, style: :bold

      case step
      when Steps::Question
        pdf.text "Question: #{step.question}", size: 10 if step.question.present?
        pdf.text "Variable: #{step.variable_name}", size: 9, style: :italic if step.variable_name.present?
      when Steps::Action
        pdf.text "Instructions: #{step.instructions&.to_plain_text}", size: 10 if step.instructions.present?
      when Steps::Message
        pdf.text "Message: #{step.content&.to_plain_text}", size: 10 if step.content.present?
      when Steps::Escalate
        pdf.text "Escalate to: #{step.target_type}", size: 10 if step.target_type.present?
        pdf.text "Priority: #{step.priority}", size: 10 if step.priority.present?
      when Steps::Resolve
        pdf.text "Resolution: #{step.resolution_type}", size: 10 if step.resolution_type.present?
      end

      if step.transitions.any?
        pdf.text "Transitions:", size: 10, style: :bold
        step.transitions.each do |transition|
          target_name = transition.target_step&.title || transition.target_step_id.to_s
          condition_text = transition.condition.present? ? " (if #{transition.condition})" : ""
          pdf.text "  -> #{target_name}#{condition_text}", size: 9
        end
      end

      pdf.move_down 10
    end
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

  def ensure_draft_workflow!
    unless @workflow.status == 'draft' && @workflow.user == current_user
      redirect_to workflows_path, alert: "This workflow is not a draft or you don't have permission to edit it."
    end
  end

  def workflow_params
    # lock_version is used for optimistic locking to prevent race conditions
    # graph_mode is for DAG-based workflows
    # Steps are managed via AR Step records, not workflow params
    params.require(:workflow).permit(:title, :description, :is_public, :lock_version,
                                     :graph_mode,
                                     :visual_editor_steps_json, :editor_mode)
  end

  def workflow_step1_params
    # Permit title, description, and graph_mode for step 1
    params.require(:workflow).permit(:title, :description, :graph_mode)
  end

  def workflow_step2_params
    # Permit steps for step 2
    # NOTE: Must match workflow_params to ensure all nested structures are permitted
    # Missing fields identified in Phase 1 diagnosis: :id, :checkpoint_message, :jumps, output_fields
    # Added: target_workflow_id for sub-flow steps, transitions for graph mode
    # Added: visual_editor_steps_json, editor_mode, start_node_uuid for visual editor
    params.require(:workflow).permit(:visual_editor_steps_json, :editor_mode, :start_node_uuid,
                                     steps: [
                                       :index, :id, :type, :title, :description, :question, :answer_type, :variable_name,
                                       :else_path, :action_type, :instructions,
                                       :target_workflow_id,
                                       :content, :can_resolve,
                                       :target_type, :target_value, :priority, :reason_required, :notes,
                                       :resolution_type, :resolution_code, :notes_required, :survey_trigger,
                                       { options: %i[label value],
                                         branches: %i[condition path],
                                         jumps: %i[condition next_step_id],
                                         transitions: %i[target_uuid condition label],
                                         attachments: [],
                                         output_fields: %i[name value] }
                                     ])
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

  def detect_file_format(filename, content_type)
    extension = File.extname(filename).downcase

    case extension
    when '.json'
      :json
    when '.csv'
      :csv
    when '.yaml', '.yml'
      :yaml
    when '.md', '.markdown'
      :markdown
    else
      # Try content type as fallback
      case content_type
      when 'application/json', 'text/json'
        :json
      when 'text/csv', 'application/csv'
        :csv
      when 'text/x-yaml', 'application/x-yaml'
        :yaml
      when 'text/markdown', 'text/x-markdown'
        :markdown
      end
    end
  end

  # Truncate an array of messages to prevent cookie overflow
  # Rails session cookies have a 4KB limit
  def truncate_for_flash(messages, max_items: 3, max_length: 500)
    return "" if messages.blank?

    truncated = messages.first(max_items).map { |m| m.to_s.truncate(150) }
    result = truncated.join(", ")

    if messages.length > max_items
      result += " (and #{messages.length - max_items} more...)"
    end

    result.truncate(max_length)
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
