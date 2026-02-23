class TemplatesController < ApplicationController
  before_action :ensure_editor_or_admin!, only: [:use]

  def index
    base_scope = current_user&.admin? ? Template.all : Template.public_templates
    @templates = if params[:search].present?
                   base_scope.search(params[:search])
                 else
                   base_scope
                 end
    @categories = base_scope.distinct.pluck(:category).compact.sort
    @templates = @templates.where(category: params[:category]) if params[:category].present?
    @templates = @templates.order(:name)
  end

  def show
    @template = Template.find(params[:id])
    # Only show public templates to non-admins
    unless current_user&.admin? || @template.is_public?
      redirect_to templates_path, alert: "You don't have permission to view this template."
    end
  end

  def use
    @template = Template.find(params[:id])

    # Enforce same visibility rules as show
    unless current_user&.admin? || @template.is_public?
      redirect_to templates_path, alert: "You don't have permission to use this template."
      return
    end

    # Deep copy the workflow_data to avoid modifying the template
    workflow_data = JSON.parse(@template.workflow_data.to_json)

    # Ensure all steps have IDs and normalize the data
    workflow_data = normalize_template_steps(workflow_data) if workflow_data.present?

    # Detect graph mode from step data (presence of transitions arrays)
    is_graph_mode = workflow_data&.any? { |step| step['transitions'].is_a?(Array) }
    start_node_uuid = is_graph_mode && workflow_data.present? ? workflow_data.first['id'] : nil

    @workflow = current_user.workflows.build(
      title: "#{@template.name} - #{Time.current.strftime('%Y-%m-%d')}",
      description: @template.description,
      steps: workflow_data,
      graph_mode: is_graph_mode,
      start_node_uuid: start_node_uuid
    )

    if @workflow.save
      redirect_to edit_workflow_path(@workflow), notice: "Workflow created from template. Customize it as needed."
    else
      redirect_to templates_path, alert: "Failed to create workflow from template: #{@workflow.errors.full_messages.join(', ')}"
    end
  end

  private

  # Normalize template steps to ensure they're in the correct format for workflow creation
  # Handles both graph mode (transitions) and legacy linear mode (branches)
  def normalize_template_steps(steps)
    return [] unless steps.is_a?(Array)

    steps.each do |step|
      next unless step.is_a?(Hash)

      # Assign ID if missing
      step['id'] ||= SecureRandom.uuid

      # Ensure title is present (required)
      step['title'] ||= "Untitled Step"

      # Normalize graph mode transitions
      if step['transitions'].is_a?(Array)
        step['transitions'] = step['transitions'].select do |transition|
          transition.is_a?(Hash) && transition['target_uuid'].present?
        end
      end
    end

    steps
  end
end
