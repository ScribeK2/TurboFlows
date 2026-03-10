module StepHelper
  # Unified field access for both AR Step objects and legacy JSONB hashes.
  # Returns the value of a field from either format.
  #
  # Examples:
  #   step_field(step, 'title')         # works for Hash or Step
  #   step_field(step, 'instructions')  # returns plain text for AR rich text fields
  #   step_field(step, 'type')          # returns "action" for both formats
  def step_field(step, field)
    if step.is_a?(Step)
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
    elsif step.is_a?(Hash)
      step[field.to_s] || step[field.to_sym]
    end
  end

  # Check if step is an AR Step object (vs legacy Hash)
  def ar_step?(step)
    step.is_a?(Step)
  end

  # Render rich text content for AR steps or markdown for JSONB steps.
  # Used in scenario player and workflow show views.
  def render_step_content(step, field, variables = {})
    if ar_step?(step)
      rt = step.try(field)
      if rt.present? && variables.present?
        VariableInterpolator.interpolate_rich_text(rt, variables).html_safe
      elsif rt.present?
        rt.to_s.html_safe
      else
        "".html_safe
      end
    else
      text = step[field.to_s]
      if text.present? && variables.present?
        render_step_markdown(VariableInterpolator.interpolate(text, variables))
      elsif text.present?
        render_step_markdown(text)
      else
        "".html_safe
      end
    end
  end

  # Get steps from a workflow, preferring AR steps over JSONB
  def workflow_display_steps(workflow)
    if workflow.workflow_steps.any?
      workflow.workflow_steps.includes(:transitions)
    else
      workflow.steps || []
    end
  end

  # Serialize AR steps to JSON-compatible array for the visual editor.
  # Returns the same shape that VisualEditorService expects.
  def serialize_steps_for_editor(workflow)
    workflow.workflow_steps.includes(:transitions).map do |s|
      data = {
        "id" => s.uuid,
        "type" => s.type.demodulize.underscore,
        "title" => s.title,
        "description" => s.try(:description).to_s,
        "transitions" => s.transitions.map { |t|
          target = Step.find_by(id: t.target_step_id)
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
