module StepHelper
  # Unified field access for AR Step objects.
  # Handles type normalization, UUID mapping, and rich text extraction.
  #
  # Examples:
  #   step_field(step, 'title')         # returns step.title
  #   step_field(step, 'instructions')  # returns plain text for rich text fields
  #   step_field(step, 'type')          # returns "action" (not "Steps::Action")
  def step_field(step, field)
    case field.to_s
    when "type"
      step.type.demodulize.underscore
    when "id"
      step.uuid
    when "target_workflow_id"
      step.respond_to?(:sub_flow_workflow_id) ? step.sub_flow_workflow_id : nil
    when "instructions", "content", "notes"
      # Rich text fields - return body as string for interpolation
      rt = step.try(field)
      rt.respond_to?(:body) ? rt.body.to_s : rt.to_s
    else
      step.try(field)
    end
  end

  # Render rich text content with optional variable interpolation.
  # Used in scenario player and workflow show views.
  #
  # Variables are HTML-escaped before interpolation to prevent XSS when
  # the result is marked html_safe (the surrounding Action Text HTML is trusted,
  # but user-supplied variable values are not).
  def render_step_content(step, field, variables = {})
    rt = step.try(field)
    if rt.present? && variables.present?
      sanitized_vars = variables.transform_values { |v| ERB::Util.html_escape(v.to_s) }
      VariableInterpolator.interpolate_rich_text(rt, sanitized_vars).html_safe
    elsif rt.present?
      rt.to_s.html_safe
    else
      "".html_safe
    end
  end

  # Combines outcome_summary + condition_summary for collapsed card display
  def step_summary_text(step)
    parts = [step.outcome_summary, step.condition_summary].compact.reject(&:blank?)
    parts.join(" | ")
  end

  # Wraps {{variable}} patterns in highlighted spans, HTML-escapes surrounding text
  def highlight_variables(text)
    return "".html_safe if text.blank?

    # Split on {{...}} patterns, escape non-variable parts, wrap variables
    result = text.gsub(/\{\{(\w+)\}\}/) do
      variable = Regexp.last_match(1)
      "<span class=\"variable-tag\">{{#{ERB::Util.html_escape(variable)}}}</span>"
    end

    # Escape everything that's NOT already in a variable-tag span
    # Strategy: split on our spans, escape the rest, rejoin
    parts = result.split(/(<span class="variable-tag">.*?<\/span>)/)
    parts.map! { |part| part.start_with?("<span") ? part : ERB::Util.html_escape(part) }
    parts.join.html_safe
  end

  # Get steps from a workflow for display purposes
  def workflow_display_steps(workflow)
    workflow.steps.includes(:transitions)
  end

  # Serialize AR steps to JSON-compatible array for the visual editor.
  # Returns the same shape that VisualEditorService expects.
  def serialize_steps_for_editor(workflow)
    steps = workflow.steps
    steps = steps.includes(:transitions) if steps.respond_to?(:includes)

    # Pre-build lookup hash to avoid N+1 queries when resolving transition targets
    all_steps = steps.to_a
    steps_by_id = all_steps.index_by(&:id)

    all_steps.map do |s|
      data = {
        "id" => s.uuid,
        "type" => s.type.demodulize.underscore,
        "title" => s.title,
        "description" => s.try(:description).to_s,
        "position_x" => s.position_x,
        "position_y" => s.position_y,
        "transitions" => s.transitions.map { |t|
          target = steps_by_id[t.target_step_id]
          {
            "target_uuid" => target&.uuid,
            "condition" => t.condition,
            "label" => t.label
          }
        }.select { |t| t["target_uuid"].present? }
      }

      case s
      when Steps::Question
        data.merge!("question" => s.question, "answer_type" => s.answer_type,
                     "variable_name" => s.variable_name, "options" => s.options)
      when Steps::Action
        data.merge!("action_type" => s.action_type, "can_resolve" => s.can_resolve,
                     "instructions" => s.instructions&.body&.to_s || "",
                     "output_fields" => s.output_fields, "jumps" => s.jumps)
      when Steps::Message
        data.merge!("content" => s.content&.body&.to_s || "", "can_resolve" => s.can_resolve,
                     "jumps" => s.jumps)
      when Steps::Escalate
        data.merge!("target_type" => s.target_type, "target_value" => s.target_value,
                     "priority" => s.priority, "reason_required" => s.reason_required,
                     "notes" => s.notes&.body&.to_s || "")
      when Steps::Resolve
        data.merge!("resolution_type" => s.resolution_type, "resolution_code" => s.resolution_code,
                     "notes_required" => s.notes_required, "survey_trigger" => s.survey_trigger)
      when Steps::SubFlow
        data.merge!("target_workflow_id" => s.sub_flow_workflow_id,
                     "variable_mapping" => s.variable_mapping)
      end

      data
    end
  end
end
