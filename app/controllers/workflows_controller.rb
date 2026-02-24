class WorkflowsController < ApplicationController
  before_action :set_workflow,
                only: %i[show edit update destroy export export_pdf preview variables save_as_template start begin_execution step1 update_step1 step2 update_step2 step3 create_from_draft render_step]
  before_action :ensure_draft_workflow!, only: %i[step1 update_step1 step2 update_step2 step3 create_from_draft]
  before_action :ensure_editor_or_admin!, only: %i[new create import import_file start_wizard]
  before_action :ensure_can_view_workflow!, only: %i[show export export_pdf start begin_execution]
  before_action :ensure_can_edit_workflow!, only: %i[edit update save_as_template]
  before_action :ensure_can_delete_workflow!, only: [:destroy]
  before_action :parse_transitions_json, only: %i[create update update_step2]

  def index
    @status_filter = params[:status].presence || 'all'
    @sort_by = params[:sort].presence || 'recent'

    # Build base scope based on status filter
    case @status_filter
    when 'draft'
      # Only show the current user's own drafts (drafts are never shared)
      @workflows = current_user.workflows.drafts
    when 'published'
      # Published workflows visible to the current user
      @workflows = Workflow.visible_to(current_user)
    else
      # "all" — published visible + own drafts
      published_ids = Workflow.visible_to(current_user).select(:id)
      own_draft_ids = current_user.workflows.drafts.select(:id)
      @workflows = Workflow.where(id: published_ids).or(Workflow.where(id: own_draft_ids))
    end

    # Eager load associations to prevent N+1 queries (especially important for caching)
    @workflows = @workflows.includes(:user)
                           .search_by(params[:search])

    # Apply sort order
    @workflows = case @sort_by
                 when 'alphabetical'
                   @workflows.order(Arel.sql('LOWER(title) ASC'))
                 when 'most_steps'
                   @workflows.order(Arel.sql("COALESCE(json_array_length(steps), 0) DESC"))
                 else
                   # 'recent' — order by updated_at
                   @workflows.order(updated_at: :desc)
                 end

    # Filter by group if selected
    if params[:group_id].present?
      begin
        # Check access first with a simple query
        potential_group = Group.find_by(id: params[:group_id])
        if potential_group && potential_group.can_be_viewed_by?(current_user)
          # Eager load ancestors to prevent N+1 queries in breadcrumb rendering
          # Load up to 5 levels deep (max depth) to cover all ancestors
          @selected_group = Group.includes(parent: { parent: { parent: { parent: :parent } } }).find_by(id: params[:group_id])
          @workflows = @workflows.in_group(@selected_group)
        else
          @selected_group = nil
          flash.now[:alert] = "You don't have permission to view this group."
        end
      rescue StandardError => e
        Rails.logger.error "Error loading group #{params[:group_id]}: #{e.message}\n#{e.backtrace.join("\n")}"
        @selected_group = nil
        flash.now[:alert] = "An error occurred while loading the group."
      end
    end

    # Load folders for the selected group
    if @selected_group.present?
      @folders = @selected_group.folders.ordered
      @uncategorized_workflows = @selected_group.uncategorized_workflows
                                                .includes(:user)
                                                .search_by(params[:search])
      @uncategorized_workflows = case @sort_by
                                 when 'alphabetical'
                                   @uncategorized_workflows.order(Arel.sql('LOWER(title) ASC'))
                                 when 'most_steps'
                                   @uncategorized_workflows.order(Arel.sql("COALESCE(json_array_length(steps), 0) DESC"))
                                 else
                                   @uncategorized_workflows.order(updated_at: :desc)
                                 end

      if @folders.present?
        @workflows_by_folder = {}
        @folders.each do |folder|
          folder_workflows = @workflows.joins(:group_workflows)
                                       .where(group_workflows: { folder_id: folder.id })
          @workflows_by_folder[folder.id] = folder_workflows
        end
      end
    end

    # Load accessible groups for sidebar
    # If no groups exist, show all workflows (backward compatibility)
    # Eager load children to prevent N+1 queries when rendering the tree
    @accessible_groups = Group.visible_to(current_user)
                              .roots
                              .includes(:children)
                              .order(:position, :name)

    # Fallback: if no groups exist at all, don't filter by groups
    if @accessible_groups.empty? && !current_user&.admin?
      # For non-admins with no groups, show all workflows they have access to
      # (this maintains backward compatibility)
    end

    @search_query = params[:search]

    # Pagination (HTML only — JSON returns all results for API consumers)
    @page = [ (params[:page] || 1).to_i, 1 ].max
    @per_page = 10
    @total_count = @workflows.count
    @total_pages = [ (@total_count.to_f / @per_page).ceil, 1 ].max
    @page = [ @page, @total_pages ].min
    @workflows_paginated = @workflows.limit(@per_page).offset((@page - 1) * @per_page)

    respond_to do |format|
      format.html
      format.json do
        # Return simplified workflow data for API consumers (e.g., sub-flow selector)
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

  def show; end

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
  end

  def create
    @workflow = current_user.workflows.build(workflow_params)

    if @workflow.save
      # Assign groups if provided
      if params[:workflow][:group_ids].present?
        group_ids = Array(params[:workflow][:group_ids]).reject(&:blank?)
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

    begin
      Workflow.transaction do
        # Check for version conflict if client sent a lock_version
        if client_lock_version.present? && client_lock_version > 0 && (@workflow.lock_version != client_lock_version)
          @workflow.errors.add(:base, "This workflow was modified by another user. Please refresh and try again.")
          raise ActiveRecord::StaleObjectError.new(@workflow, "update")
        end

        if @workflow.update(workflow_params)
          # Update group assignments
          if params[:workflow][:group_ids].present?
            @workflow.group_workflows.destroy_all
            group_ids = Array(params[:workflow][:group_ids]).reject(&:blank?)
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

  def destroy
    @workflow.destroy
    redirect_to workflows_path, notice: "Workflow was successfully deleted."
  end

  def export
    # Build comprehensive export data including Graph Mode fields
    export_data = {
      title: @workflow.title,
      description: @workflow.description_text || "",
      graph_mode: @workflow.graph_mode?,
      start_node_uuid: @workflow.start_node_uuid,
      steps: @workflow.steps || [],
      exported_at: Time.current.iso8601,
      export_version: "2.0" # Version 2.0 indicates Graph Mode support
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

    # Show workflow mode
    mode_text = @workflow.graph_mode? ? "Graph Mode" : "Linear Mode"
    pdf.text "Mode: #{mode_text}", size: 10, style: :italic
    pdf.move_down 20

    if @workflow.steps.present?
      @workflow.steps.each_with_index do |step, index|
        # Step header with type badge
        step_type = step['type']&.capitalize || 'Unknown'
        pdf.text "#{index + 1}. #{step['title']} [#{step_type}]", size: 14, style: :bold
        pdf.text step['description'], size: 10 if step['description'].present?

        # Type-specific content
        case step['type']
        when 'question'
          pdf.text "Question: #{step['question']}", size: 10 if step['question'].present?
          pdf.text "Variable: #{step['variable_name']}", size: 9, style: :italic if step['variable_name'].present?
        when 'action'
          pdf.text "Instructions: #{step['instructions']}", size: 10 if step['instructions'].present?
        when 'message'
          pdf.text "Message: #{step['content']}", size: 10 if step['content'].present?
        when 'escalate'
          pdf.text "Escalate to: #{step['target_type']}", size: 10 if step['target_type'].present?
          pdf.text "Priority: #{step['priority']}", size: 10 if step['priority'].present?
        when 'resolve'
          pdf.text "Resolution: #{step['resolution_type']}", size: 10 if step['resolution_type'].present?
        end

        # Show transitions for graph mode workflows
        if @workflow.graph_mode? && step['transitions'].present?
          pdf.text "Transitions:", size: 10, style: :bold
          step['transitions'].each do |transition|
            target_step = @workflow.find_step_by_id(transition['target_uuid'])
            target_name = target_step ? target_step['title'] : transition['target_uuid']
            condition_text = transition['condition'].present? ? " (if #{transition['condition']})" : ""
            # Use ASCII arrow instead of Unicode to avoid encoding issues
            pdf.text "  -> #{target_name}#{condition_text}", size: 9
          end
        end

        pdf.move_down 10
      end
    end

    send_data pdf.render, filename: "#{@workflow.title.parameterize}.pdf", type: "application/pdf"
  end

  def preview
    # Parse step data from params
    step_data = parse_step_from_params
    step_index = params[:step_index].to_i

    # Generate sample variables for interpolation preview
    # This allows users to see what variables will look like when interpolated
    sample_variables = generate_sample_variables(@workflow)

    # Render preview partial within Turbo Frame
    render partial: "workflows/preview_pane",
           locals: { step: step_data, index: step_index, sample_variables: sample_variables },
           formats: [:html]
  end

  def variables
    # Return available variables from workflow
    variables = @workflow.variables

    render json: { variables: variables }
  end

  # Sprint 3: Render step HTML for dynamic step creation
  # This allows the JavaScript to request server-rendered HTML for new steps,
  # ensuring all the new Sprint 2/3 features are included
  def render_step
    Rails.logger.debug { "[render_step] Params: #{params.inspect}" }

    step_type = params[:step_type]
    step_index = params[:step_index].to_i

    # Convert step_data to hash with indifferent access (allows both string and symbol keys)
    raw_step_data = params[:step_data]
    step_data = if raw_step_data.is_a?(ActionController::Parameters)
                  raw_step_data.to_unsafe_h.with_indifferent_access
                elsif raw_step_data.is_a?(Hash)
                  raw_step_data.with_indifferent_access
                else
                  {}.with_indifferent_access
                end

    Rails.logger.debug { "[render_step] step_type=#{step_type}, step_index=#{step_index}, step_data=#{step_data.inspect}" }

    # Build a step hash from the parameters
    step = {
      'id' => SecureRandom.uuid,
      'type' => step_type,
      'title' => step_data[:title] || '',
      'description' => step_data[:description] || ''
    }

    # Add type-specific fields
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

    # Render the step_item partial
    begin
      render partial: 'workflows/step_item',
             locals: {
               step: step,
               index: step_index,
               workflow: @workflow,
               expanded: true
             },
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

    # Merge submitted steps with existing steps to preserve fields not in form
    if permitted_params[:steps].present? && @workflow.steps.present?
      permitted_params[:steps] = StepMergeService.new(
        existing_steps: @workflow.steps,
        submitted_steps: permitted_params[:steps]
      ).call
    end

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
                                     steps: [
                                       :index, :id, :type, :title, :description, :question, :answer_type, :variable_name,
                                       :else_path, :action_type, :instructions,
                                       :target_workflow_id,
                                       :content,
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
    params.require(:workflow).permit(steps: [
                                       :index, :id, :type, :title, :description, :question, :answer_type, :variable_name,
                                       :else_path, :action_type, :instructions,
                                       :target_workflow_id,
                                       :content,
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
