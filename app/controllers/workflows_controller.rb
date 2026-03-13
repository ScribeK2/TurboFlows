class WorkflowsController < ApplicationController
  before_action :set_workflow,
                only: %i[show edit update destroy export export_pdf preview variables save_as_template start begin_execution step1 update_step1 step2 update_step2 step3 create_from_draft render_step publish versions sync_steps]
  before_action :ensure_draft_workflow!, only: %i[step1 update_step1 step2 update_step2 step3 create_from_draft]
  before_action :ensure_editor_or_admin!, only: %i[new create import import_file start_wizard]
  before_action :ensure_can_view_workflow!, only: %i[show export export_pdf start begin_execution preview variables versions]
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
            graph_mode: w.graph_mode?,
            step_count: w.steps&.length || 0
          }
        end
        render json: workflows_data
      end
    end
  end

  def show
    preload_subflow_targets
  end

  def new
    @workflow = current_user.workflows.build(
      status: 'draft',
      title: 'Untitled Workflow',
      graph_mode: determine_graph_mode_for_new
    )
    # Save the draft immediately so the builder has a workflow ID for server-side
    # step rendering. This mirrors start_wizard and ensures addStepFromModal never
    # falls back to client-side rendering on a truly unsaved record.
    if @workflow.save
      redirect_to step1_workflow_path(@workflow)
    else
      @accessible_groups = Group.visible_to(current_user).includes(:children).order(:name)
      render :new, status: :unprocessable_content
    end
  end

  def start_wizard
    @workflow = current_user.workflows.build(
      status: 'draft',
      title: 'Untitled Workflow',
      graph_mode: determine_graph_mode_for_new
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

    incoming_steps = params[:steps] || []
    start_node_uuid = params[:start_node_uuid]

    begin
      Workflow.transaction do
        existing_steps = @workflow.workflow_steps.unscoped
          .where(workflow_id: @workflow.id)
          .includes(:transitions, :incoming_transitions)
          .index_by(&:uuid)

        incoming_uuids = Set.new
        step_records = {}

        # Phase 1: Create or update steps
        incoming_steps.each_with_index do |step_data, index|
          step_data = step_data.permit!.to_h if step_data.respond_to?(:permit!)
          uuid = step_data["id"].presence || SecureRandom.uuid
          incoming_uuids << uuid

          step_type = step_data["type"].to_s
          sti_class = step_class_for(step_type)

          if (existing = existing_steps[uuid])
            attrs = build_step_attrs(step_data, index)
            existing.update!(attrs)
            assign_rich_text_fields(existing, step_data)
            step_records[uuid] = existing
          else
            attrs = build_step_attrs(step_data, index).merge(
              workflow: @workflow,
              type: sti_class.name,
              uuid: uuid
            )
            step_record = Step.create!(attrs)
            assign_rich_text_fields(step_record, step_data)
            step_records[uuid] = step_record
          end
        end

        # Phase 2: Delete steps not in incoming set
        existing_steps.each do |uuid, step|
          unless incoming_uuids.include?(uuid)
            step.incoming_transitions.delete_all
            step.destroy!
          end
        end

        # Phase 3: Reconcile transitions
        incoming_steps.each do |step_data|
          step_data = step_data.permit!.to_h if step_data.respond_to?(:permit!)
          uuid = step_data["id"]
          source_step = step_records[uuid]
          next unless source_step

          incoming_transitions = (step_data["transitions"] || []).select { |t| t.is_a?(Hash) || t.respond_to?(:permit!) }

          desired = incoming_transitions.map do |t|
            t = t.permit!.to_h if t.respond_to?(:permit!)
            target = step_records[t["target_uuid"]]
            next nil unless target
            { target_step_id: target.id, condition: t["condition"].presence, label: t["label"].presence }
          end.compact

          existing_trans = source_step.transitions.unscoped.where(step_id: source_step.id).to_a
          existing_trans.each do |et|
            match = desired.find { |d| d[:target_step_id] == et.target_step_id && d[:condition] == et.condition }
            et.destroy! unless match
          end

          desired.each_with_index do |d, pos|
            t = Transition.find_or_initialize_by(
              step_id: source_step.id,
              target_step_id: d[:target_step_id],
              condition: d[:condition]
            )
            t.label = d[:label]
            t.position = pos
            t.save!
          end
        end

        # Phase 4: Set start step
        if start_node_uuid.present? && step_records[start_node_uuid]
          @workflow.update_column(:start_step_id, step_records[start_node_uuid].id)
        elsif step_records.values.first
          @workflow.update_column(:start_step_id, step_records.values.first.id)
        else
          @workflow.update_column(:start_step_id, nil)
        end

        @workflow.touch
      end

      render json: { success: true, lock_version: @workflow.reload.lock_version }
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  def destroy
    @workflow.destroy
    redirect_to workflows_path, notice: "Workflow was successfully deleted."
  end

  def export
    # Build comprehensive export data including Graph Mode fields
    # Use AR steps if available, otherwise fall back to JSONB
    steps_data = if @workflow.workflow_steps.any?
                   serialize_ar_steps_for_export(@workflow)
                 else
                   @workflow.steps || []
                 end

    start_uuid = if @workflow.start_step.present?
                   @workflow.start_step.uuid
                 else
                   @workflow.start_node_uuid
                 end

    export_data = {
      title: @workflow.title,
      description: @workflow.description_text || "",
      graph_mode: @workflow.graph_mode?,
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

    mode_text = @workflow.graph_mode? ? "Graph Mode" : "Linear Mode"
    pdf.text "Mode: #{mode_text}", size: 10, style: :italic
    pdf.move_down 20

    export_pdf_ar_steps(pdf) if @workflow.workflow_steps.any?

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
  # When workflow has AR steps (workflow_steps.any?), creates an AR Step record.
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

    # Try AR path if workflow has migrated steps
    if @workflow.workflow_steps.loaded? ? @workflow.workflow_steps.any? : @workflow.workflow_steps.exists?
      step_class = step_class_for(step_type)
      position = @workflow.workflow_steps.maximum(:position).to_i + 1
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
      step.save! # Persist so it gets a UUID and ID

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
        render partial: "workflows/step_item",
               locals: { step: step, index: step.position, workflow: @workflow, expanded: true },
               formats: [:html]
      rescue StandardError => e
        Rails.logger.error "[render_step] Error rendering AR step: #{e.message}"
        render plain: "Error rendering step: #{e.message}", status: :internal_server_error
      end
      return
    end

    # Legacy JSONB path
    step = {
      'id' => SecureRandom.uuid,
      'type' => step_type,
      'title' => step_data[:title] || '',
      'description' => step_data[:description] || ''
    }

    case step_type
    when 'question'
      step['question'] = step_data[:question] || ''
      step['answer_type'] = step_data[:answer_type] || 'yes_no'
      step['variable_name'] = step_data[:variable_name] || ''
      step['options'] = step_data[:options] || []
    when 'action'
      step['action_type'] = step_data[:action_type] || 'Instruction'
      step['instructions'] = step_data[:instructions] || ''
      step['attachments'] = step_data[:attachments] || []
    when 'sub_flow'
      step['target_workflow_id'] = step_data[:target_workflow_id] || ''
      step['variable_mapping'] = step_data[:variable_mapping] || {}
    end

    begin
      render partial: 'workflows/step_item',
             locals: { step: step, index: step_index, workflow: @workflow, expanded: true },
             formats: [:html]
    rescue StandardError => e
      Rails.logger.error "[render_step] Error rendering step: #{e.message}"
      Rails.logger.error e.backtrace.first(10).join("\n")
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

  def import
    # Show import form
  end

  def import_file
    unless params[:file].present?
      redirect_to import_workflows_path, alert: "Please select a file to import."
      return
    end

    uploaded_file = params[:file]
    file_content = uploaded_file.read

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
  end

  def update_step2
    permitted_params = workflow_step2_params

    # Visual editor mode: parse steps from JSON hidden input
    if params[:workflow][:editor_mode] == 'visual' && params[:workflow][:visual_editor_steps_json].present?
      begin
        visual_steps = JSON.parse(params[:workflow][:visual_editor_steps_json])
        permitted_params[:steps] = visual_steps
        if params[:workflow][:start_node_uuid].present?
          permitted_params[:start_node_uuid] = params[:workflow][:start_node_uuid]
        end
      rescue JSON::ParserError => e
        Rails.logger.error "[update_step2] Failed to parse visual editor steps: #{e.message}"
        flash[:alert] = "Failed to save visual editor changes."
        redirect_to step2_workflow_path(@workflow) and return
      end
    elsif permitted_params[:steps].present? && @workflow.steps.present?
      # List editor mode: merge submitted steps with existing steps to preserve fields not in form
      permitted_params[:steps] = StepMergeService.new(
        existing_steps: @workflow.steps,
        submitted_steps: permitted_params[:steps]
      ).call
    end

    # Remove non-model params before update
    permitted_params.delete(:visual_editor_steps_json)
    permitted_params.delete(:editor_mode)

    if @workflow.update(permitted_params)
      redirect_to step3_workflow_path(@workflow), notice: "Steps added. Let's review your workflow."
    else
      render :step2, status: :unprocessable_content
    end
  end

  def step3
    # Load draft workflow for step 3 (review and launch)
    # Preview will be shown here
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
    if @workflow.steps.blank? || @workflow.steps.empty?
      @workflow.errors.add(:base, "Workflow must have at least one step")
      render :step3, status: :unprocessable_content
      return
    end

    # Validate all steps have required fields
    @workflow.steps.each_with_index do |step, index|
      unless step.is_a?(Hash)
        @workflow.errors.add(:steps, "Step #{index + 1}: Invalid step format")
        next
      end

      unless step['type'].present?
        @workflow.errors.add(:steps, "Step #{index + 1}: Step type is required")
      end

      unless step['title'].present? || step['title'].to_s.strip.present?
        @workflow.errors.add(:steps, "Step #{index + 1}: Step title is required")
      end

      # Type-specific validation
      if step['type'] == 'question' && !step['question'].present?
        @workflow.errors.add(:steps, "Step #{index + 1}: Question text is required for question steps")
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
    return {} unless workflow&.steps.present?

    sample_vars = {}

    workflow.steps.each do |step|
      next unless step.is_a?(Hash)

      # Get variables from question steps
      if step['type'] == 'question' && step['variable_name'].present?
        var_name = step['variable_name']
        # Generate sample value based on answer type
        sample_vars[var_name] = case step['answer_type']
                                when 'yes_no'
                                  'yes'
                                when 'number'
                                  '42'
                                when 'date'
                                  Date.today.strftime('%Y-%m-%d')
                                when 'multiple_choice', 'dropdown'
                                  # Use first option if available, otherwise default
                                  if step['options'].present? && step['options'].is_a?(Array) && step['options'].first
                                    opt = step['options'].first
                                    opt.is_a?(Hash) ? (opt['value'] || opt['label'] || 'option1') : opt.to_s
                                  else
                                    'option1'
                                  end
                                else
                                  # Default text value - use step title or generic name
                                  step['title'].present? ? step['title'].split(' ').first : 'sample_value'
                                end
      end

      # Get variables from action step output_fields
      next unless step['type'] == 'action' && step['output_fields'].present? && step['output_fields'].is_a?(Array)

      step['output_fields'].each do |output_field|
        next unless output_field.is_a?(Hash) && output_field['name'].present?

        var_name = output_field['name']
        # Use the defined value if static, or generate sample if it contains interpolation
        sample_vars[var_name] = if output_field['value'].present?
                                  # If value contains {{, it's interpolated - use a placeholder
                                  if output_field['value'].include?('{{')
                                    '[interpolated]'
                                  else
                                    # Static value
                                    output_field['value']
                                  end
                                else
                                  # No value defined - use generic sample
                                  'completed'
                                end
      end
    end

    sample_vars
  end

  def set_workflow
    @workflow = Workflow.find(params[:id])
  end

  # Preload all workflows referenced by sub-flow steps to avoid N+1 queries in partials
  def preload_subflow_targets
    # AR path
    if @workflow.workflow_steps.any?
      subflow_ids = Steps::SubFlow.where(workflow_id: @workflow.id).pluck(:sub_flow_workflow_id).compact
      @subflow_targets = Workflow.where(id: subflow_ids).index_by(&:id) if subflow_ids.any?
      return
    end

    # Legacy JSONB path
    return unless @workflow&.steps.present?

    subflow_ids = @workflow.steps
      .select { |s| %w[sub_flow sub-flow].include?(s["type"]) && s["target_workflow_id"].present? }
      .map { |s| s["target_workflow_id"].to_i }
    @subflow_targets = Workflow.where(id: subflow_ids).index_by(&:id) if subflow_ids.any?
  end

  # Resolve step type string to STI class
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

  def build_step_attrs(step_data, position)
    attrs = { title: step_data["title"], position: position }

    case step_data["type"].to_s
    when "question"
      attrs.merge!(question: step_data["question"], answer_type: step_data["answer_type"],
                    variable_name: step_data["variable_name"], options: step_data["options"])
    when "action"
      attrs.merge!(can_resolve: step_data["can_resolve"] || false, action_type: step_data["action_type"],
                    output_fields: step_data["output_fields"], jumps: step_data["jumps"])
    when "message"
      attrs.merge!(can_resolve: step_data["can_resolve"] || false, jumps: step_data["jumps"])
    when "escalate"
      attrs.merge!(target_type: step_data["target_type"], target_value: step_data["target_value"],
                    priority: step_data["priority"], reason_required: step_data["reason_required"] || false)
    when "resolve"
      attrs.merge!(resolution_type: step_data["resolution_type"], resolution_code: step_data["resolution_code"],
                    notes_required: step_data["notes_required"] || false, survey_trigger: step_data["survey_trigger"] || false)
    when "sub_flow"
      attrs.merge!(sub_flow_workflow_id: step_data["target_workflow_id"], variable_mapping: step_data["variable_mapping"])
    end

    attrs
  end

  def assign_rich_text_fields(step_record, step_data)
    { "instructions" => Steps::Action, "content" => Steps::Message, "notes" => Steps::Escalate }.each do |field, klass|
      if step_record.is_a?(klass) && step_data[field].present?
        step_record.send(:"#{field}=", step_data[field])
        step_record.save!
      end
    end
  end

  # Serialize AR steps to JSONB-compatible format for export
  def serialize_ar_steps_for_export(workflow)
    workflow.workflow_steps.includes(:transitions).map do |step|
      data = {
        "id" => step.uuid,
        "type" => step.type.demodulize.underscore,
        "title" => step.title
      }

      case step
      when Steps::Question
        data["question"] = step.question
        data["answer_type"] = step.answer_type
        data["variable_name"] = step.variable_name
        data["options"] = step.options if step.options.present?
        data["can_resolve"] = step.can_resolve
      when Steps::Action
        data["instructions"] = step.instructions&.body&.to_s || ""
        data["action_type"] = step.action_type
        data["can_resolve"] = step.can_resolve
        data["output_fields"] = step.output_fields if step.output_fields.present?
      when Steps::Message
        data["content"] = step.content&.body&.to_s || ""
        data["can_resolve"] = step.can_resolve
      when Steps::Escalate
        data["target_type"] = step.target_type
        data["target_value"] = step.target_value
        data["priority"] = step.priority
        data["reason_required"] = step.reason_required
        data["notes"] = step.notes&.body&.to_s || ""
      when Steps::Resolve
        data["resolution_type"] = step.resolution_type
        data["resolution_code"] = step.resolution_code
        data["notes_required"] = step.notes_required
        data["survey_trigger"] = step.survey_trigger
      when Steps::SubFlow
        data["target_workflow_id"] = step.sub_flow_workflow_id
        data["variable_mapping"] = step.variable_mapping if step.variable_mapping.present?
      end

      if step.transitions.any?
        data["transitions"] = step.transitions.map do |t|
          target = t.target_step
          transition_data = { "target_uuid" => target.uuid }
          transition_data["condition"] = t.condition if t.condition.present?
          transition_data["label"] = t.label if t.label.present?
          transition_data
        end
      else
        data["transitions"] = []
      end

      data
    end
  end

  # PDF export for AR steps
  def export_pdf_ar_steps(pdf)
    @workflow.workflow_steps.includes(:transitions).each_with_index do |step, index|
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

      if @workflow.graph_mode? && step.transitions.any?
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


  # Determine graph_mode for new workflows
  # Graph mode is the default; use ?force_linear_mode=1 to create linear workflow
  def determine_graph_mode_for_new
    if params[:force_linear_mode].present? && FeatureFlags.allow_linear_mode_override?
      false
    else
      FeatureFlags.graph_mode_default?
    end
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
    # Permit nested steps hash structure
    # lock_version is used for optimistic locking to prevent race conditions
    # graph_mode and start_node_uuid are for DAG-based workflows
    params.require(:workflow).permit(:title, :description, :is_public, :lock_version,
                                     :graph_mode, :start_node_uuid,
                                     :visual_editor_steps_json, :editor_mode,
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
      "survey_trigger" => step_params[:survey_trigger] || ""
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
