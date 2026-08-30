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
    parts = [step.outcome_summary, step.condition_summary].compact.compact_blank
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
    parts = result.split(%r{(<span class="variable-tag">.*?</span>)})
    parts.map! { |part| part.start_with?("<span") ? part : ERB::Util.html_escape(part) }
    parts.join.html_safe
  end

  # Get steps from a workflow for display purposes
  def workflow_display_steps(workflow)
    workflow.steps.includes(:transitions)
  end
end
