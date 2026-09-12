# Workflow View Helpers
module WorkflowsHelper
  DEFAULT_SORT = "recent".freeze

  include StepTypeIcons
  include RailsIcons::Helpers::IconHelper

  # POST, not GET: Turbo 8 prefetches GET links on hover, and creating a draft
  # is a write. turbo_prefetch: false is a second guard if this is ever turned
  # back into a link. The nav menu lives in a turbo frame, so callers there
  # must pass form: { data: { turbo_frame: "_top" } }.
  def start_workflow_button(label, html_class:, icon_class: "icon icon--sm",
                            aria_label: "Create a new workflow", form: {})
    form_data = (form[:data] || {}).merge(turbo_prefetch: false)
    button_to workflows_path,
              method: :post,
              class: html_class,
              form: form.merge(data: form_data),
              data: { turbo_prefetch: false },
              aria: { label: aria_label } do
      safe_join([icon("plus", class: icon_class), label])
    end
  end

  def workflow_open_path(workflow)
    if workflow.can_be_edited_by?(current_user)
      workflow_path(workflow, edit: true)
    else
      workflow_path(workflow)
    end
  end

  # ============================================================================
  # Step Type Helpers
  # ============================================================================

  # Step type → Heroicon name (24/outline). Single source of truth for which
  # Heroicon represents each step type — change here to update everywhere.
  STEP_TYPE_ICONS = {
    'question' => 'question-mark-circle',
    'action' => 'bolt',
    'sub_flow' => 'arrows-right-left',
    'message' => 'chat-bubble-bottom-center-text',
    'escalate' => 'exclamation-triangle',
    'resolve' => 'check-circle',
    'form' => 'document-text'
  }.freeze

  DEFAULT_STEP_ICON = 'document'.freeze

  STEP_TYPE_LABELS = {
    'question' => 'Question',
    'action' => 'Action',
    'message' => 'Message',
    'sub_flow' => 'Sub-flow',
    'escalate' => 'Escalate',
    'resolve' => 'Resolve',
    'form' => 'Form'
  }.freeze

  STEP_TYPE_BADGE_CLASSES = {
    'question' => 'badge--question',
    'action' => 'badge--action',
    'message' => 'badge--message',
    'sub_flow' => 'badge--sub-flow',
    'escalate' => 'badge--escalate',
    'resolve' => 'badge--resolve',
    'form' => 'badge--form'
  }.freeze

  ANSWER_TYPE_LABELS = {
    'yes_no' => 'Yes / No',
    'multiple_choice' => 'Multiple Choice',
    'text' => 'Text Input',
    'number' => 'Number',
    'dropdown' => 'Dropdown'
  }.freeze

  # Get a user-friendly label for a step type
  # The seven step types, in the order they are offered. One list: the type
  # picker and the builder's empty state each had their own, and the empty
  # state's was a three-item subset with no descriptions — so the first control
  # a new author meets was the worse of the two, and it omitted Resolve, which
  # every workflow is required to have.
  STEP_TYPE_OPTIONS = [
    { type: "question", name: "Question", desc: "Ask for information" },
    { type: "action", name: "Action", desc: "Perform a task" },
    { type: "message", name: "Message", desc: "Display information" },
    { type: "form", name: "Form", desc: "Collect structured data" },
    { type: "escalate", name: "Escalate", desc: "Transfer to another team" },
    { type: "resolve", name: "Resolve", desc: "Mark as completed" },
    { type: "sub_flow", name: "Sub-Flow", desc: "Run another workflow" }
  ].freeze

  # 1-based position in the workflow's ordered step list, keyed by uuid.
  #
  # Never render `step.position` directly. It is 0-based in workflows built by a
  # service (import, templates) and 1-based in ones built through the UI, so the
  # same builder called the first step "Step 0" in one workflow and "Step 1" in
  # another — and the step rows, the "→ Step N" summaries and the health panel
  # each read it separately, so fixing one left the others wrong.
  def step_connection_summary(targets, ordinals)
    titles = targets.map do |target|
      name = target.title.presence || "Untitled"
      n = ordinals[target.uuid]
      n ? "#{name} · #{n}" : name
    end
    "→ #{titles.join(', ')}"
  end

  # Computed, not memoised: a helper's instance variables live in the view
  # context, so caching here would outlive the workflow it was built for.
  # Callers that render a list compute it once and pass it down.
  def step_ordinals(workflow)
    workflow.steps.ordered.each_with_index.to_h { |step, index| [step.uuid, index + 1] }
  end

  def step_type_options
    STEP_TYPE_OPTIONS
  end

  def step_type_label(type)
    STEP_TYPE_LABELS[type] || type&.titleize || 'Step'
  end

  # Render the Heroicon for a given step type. Delegates to rails_icons.
  def step_type_svg_icon(type, css_classes: "icon")
    icon STEP_TYPE_ICONS.fetch(type, DEFAULT_STEP_ICON), class: css_classes
  end

  private

  # Get CSS classes for a step type badge
  def step_type_badge_classes(type)
    modifier = STEP_TYPE_BADGE_CLASSES[type] || 'badge--default'
    "badge #{modifier}"
  end

  # ============================================================================
  # Answer Type Helpers
  # ============================================================================

  # Get a user-friendly label for an answer type
  def answer_type_label(type)
    ANSWER_TYPE_LABELS[type] || type&.titleize || 'Unknown'
  end

  # ============================================================================
  # Condition Display Helpers
  # ============================================================================

  # Format a condition for human-readable display
  # Converts "variable == 'value'" to "variable is value"
  def format_condition_for_display(condition)
    return 'Not set' if condition.blank?

    # Parse the condition
    if (match = condition.match(/^(\w+)\s*(==|!=|>|>=|<|<=)\s*['"]?([^'"]*?)['"]?$/))
      variable, operator, value = match.captures

      operator_text = case operator
                      when '==' then 'is'
                      when '!=' then 'is not'
                      when '>' then 'is greater than'
                      when '>=' then 'is at least'
                      when '<' then 'is less than'
                      when '<=' then 'is at most'
                      else operator
                      end

      "#{variable} #{operator_text} \"#{value}\""
    else
      condition
    end
  end

  # Get CSS classes for the condition display
  def condition_display_classes(condition)
    if condition.present?
      "text-sm font-medium"
    else
      "text-sm is-disabled"
    end
  end

  # ============================================================================
  # Step Reference Helpers
  # ============================================================================

  # Resolve a step reference (ID or title) to a display name
  def resolve_step_reference(workflow, reference)
    return nil if reference.blank? || workflow.nil?

    title = workflow.resolve_step_reference_to_title(reference)
    title || reference
  end

  # Get step options for a select dropdown
  # Returns an array of [display_name, value] pairs
  def step_options_for_select(workflow, exclude_step_id: nil)
    return [] unless workflow&.steps&.any?

    workflow.steps.order(:position).map.with_index do |step, index|
      next nil if step.title.blank?
      next nil if exclude_step_id && step.uuid == exclude_step_id

      [
        "#{step_type_icon(step.step_type)} #{index + 1}. #{step.title}",
        step.title
      ]
    end.compact
  end

  # ============================================================================
  # Variable Helpers
  # ============================================================================

  # Get variable options for a select dropdown
  # Returns an array of [display_name, value] pairs
  def variable_options_for_select(workflow)
    return [] unless workflow.respond_to?(:variables_with_metadata)

    workflow.variables_with_metadata.map do |var|
      [var[:display_name], var[:name]]
    end
  end

  # Custom's sentence lists every question in the workflow. The open step
  # has to lead or the author is staring at someone else's title.
  def condition_sentence_variables(workflow, current_step)
    vars = workflow.variables_with_metadata
    return vars unless current_step.is_a?(Steps::Question) && current_step.variable_name.present?

    name = current_step.variable_name
    this, others = vars.partition { |var| var[:name] == name }
    this + others
  end

  # Get the answer type for a variable
  def variable_answer_type(workflow, variable_name)
    return nil unless workflow.respond_to?(:variables_with_metadata)

    var = workflow.variables_with_metadata.find { |v| v[:name] == variable_name }
    var&.dig(:answer_type)
  end

  # ============================================================================
  # Workflow Icon
  # ============================================================================

  # Returns a simple workflow/flowchart SVG icon colored by the dominant step type.
  def workflow_list_icon(workflow)
    dominant = workflow.dominant_step_type || 'question'
    hue_var = "--hue-#{dominant == 'sub_flow' ? 'subflow' : dominant}"

    content_tag(:div, class: "wf-list-item__icon", style: "--step-hue: var(#{hue_var});") do
      icon "clipboard-document-check", class: "wf-list-item__icon-svg"
    end
  end

  # Filters the index toolbar reports as active. Drives the "Filters (n)" count
  # and whether "Show All" is worth offering. Mirrors the params WorkflowsFilter
  # actually reads.
  def active_workflow_filters(selected_group: nil)
    filters = []
    filters << :group if selected_group.present?
    filters << :status if params[:status].present? && params[:status] != "all"
    filters << :search if params[:search].present?
    filters << :owner if params[:owner] == WorkflowsFilter::OWNER_ME
    filters << :sort if params[:sort].present? && params[:sort] != DEFAULT_SORT
    filters
  end
end
