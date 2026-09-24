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
      name = step_display_title(target)
      n = ordinals[target.uuid]
      n ? "#{name} · #{n}" : name
    end
    "→ #{titles.join(', ')}"
  end

  # What a step is called wherever it is named: its title, or "Untitled"
  # plus its type when it has none. The panel's door rows said "Untitled"
  # while the list, jump chips and dialog said "Untitled Action" (QA B-007).
  def step_display_title(step)
    step.title.presence || "Untitled #{step.step_type.titleize}"
  end

  # Accessible names for a door's action buttons (steps/_doors) and the row
  # stub that opens the type picker for it (workflows/_step_node) - every one
  # of them repeats the same visible text ("New step", "Use existing…",
  # "Change", "Remove", "→ add step") once per door, with only a sibling span
  # telling doors apart. A screen reader hears a list of identical names; this
  # names WHICH door. The :next door carries no visible label of its own (see
  # steps/_doors: `door.label unless door.kind == :next`), so it reads as
  # "after this one" rather than quoting the literal word "Next".
  def door_action_aria_label(door, action)
    case action
    when :new_step
      door.kind == :next ? "New step after this one" : "New step for “#{door.label}”"
    when :use_existing
      door.kind == :next ? "Use an existing step after this one" : "Use an existing step for “#{door.label}”"
    when :change
      door.kind == :next ? "Change what this step leads to" : "Change where “#{door.label}” leads"
    when :remove
      door.kind == :next ? "Remove this connection" : "Remove the “#{door.label}” connection"
    end
  end

  # One number per step, in the builder outline's reading order (StepOutline).
  # Every "step N" in the builder - row badge, door rows, the Use existing
  # dialog, the health panel, jump chips - goes through here, so they agree by
  # construction. Derived on every read; nothing is persisted.
  #
  # This BUILDS an outline (3 queries and a walk). A render that already holds
  # one - every builder stream and broadcast passes its request's one down as
  # `outline:` - reads `outline.ordinals` instead; this is for a partial
  # rendered on its own (the health and flow-diagram panels).
  def step_ordinals(workflow)
    StepOutline.for(workflow).ordinals
  end

  # One section of the health panel, as a flat list of [step uuid, issue], with
  # the rows a person can act on first.
  #
  # The panel used to iterate the issue hash, which is keyed by step uuid, so
  # the order on screen was the order steps happened to be created in. A
  # first-timer therefore read "8 errors" as eight separate problems, with the
  # three that carry a Fix button scattered among five that are downstream of
  # them. Ordering is the whole change: nothing is hidden, nothing is
  # downgraded, and the counts are untouched.
  #
  # sort_by with the original index keeps it stable, so within each group the
  # rows stay in the order the check produced them.
  def health_panel_rows(health, &)
    rows = health.issues.flat_map do |uuid, issues|
      issues.select(&).map { |issue| [uuid, issue] }
    end

    rows.each_with_index.sort_by { |(_uuid, issue), index| [issue[:fixable] && issue[:fix_type] ? 0 : 1, index] }
        .map(&:first)
  end

  # The publish confirmation stops for a set, for a workflow that is not ready,
  # or both. The button has to name whichever reason applies — "Publish all 4"
  # on a thin single workflow would be wrong twice over.
  def publish_button_label(publishing_set, not_ready, member_count)
    return "Publish all #{member_count} anyway" if publishing_set && not_ready
    return "Publish all #{member_count}" if publishing_set

    "Publish anyway"
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
    if (match = condition.match(/^(\w+)\s*(==|!=|>=|<=|>|<)\s*['"]?([^'"]*?)['"]?$/))
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
