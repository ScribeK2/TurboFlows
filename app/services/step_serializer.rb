class StepSerializer
  def self.call(workflow)
    new(workflow).call
  end

  def initialize(workflow)
    @workflow = workflow
  end

  def call
    @workflow.steps.includes(:transitions).map { |step| serialize_step(step) }
  end

  private

  def serialize_step(step)
    data = {
      "id" => step.uuid,
      "type" => step.type.demodulize.underscore,
      "title" => step.title,
      "position" => step.position
    }
    data["help_text"] = step.help_text if step.help_text.present?
    data["reference_url"] = step.reference_url if step.reference_url.present?

    merge_type_specific_fields(data, step)
    data["transitions"] = serialize_transitions(step)
    data
  end

  def merge_type_specific_fields(data, step)
    case step
    when Steps::Question
      data.merge!(
        "question" => step.question,
        "answer_type" => step.answer_type,
        "variable_name" => step.variable_name,
        "can_resolve" => step.can_resolve
      )
      data["options"] = step.options if step.options.present?
    when Steps::Action
      data.merge!(
        "instructions" => rich_text_html(step.instructions),
        "action_type" => step.action_type,
        "can_resolve" => step.can_resolve
      )
      data["output_fields"] = step.output_fields if step.output_fields.present?
      data["jumps"] = step.jumps if step.jumps.present?
    when Steps::Message
      data["content"] = rich_text_html(step.content)
      data["can_resolve"] = step.can_resolve
      data["jumps"] = step.jumps if step.jumps.present?
    when Steps::Escalate
      data.merge!(
        "target_type" => step.target_type,
        "target_value" => step.target_value,
        "priority" => step.priority,
        "reason_required" => step.reason_required,
        "notes" => rich_text_html(step.notes)
      )
    when Steps::Resolve
      data.merge!(
        "resolution_type" => step.resolution_type,
        "description" => rich_text_html(step.description),
        "notes_required" => step.notes_required,
        "survey_trigger" => step.survey_trigger
      )
      data["resolution_code"] = step.resolution_code if step.resolution_code.present?
    when Steps::Form
      data["instructions"] = rich_text_html(step.instructions)
      data["options"] = step.options if step.options.present?
    when Steps::SubFlow
      data["target_workflow_id"] = step.sub_flow_workflow_id
      data["variable_mapping"] = step.variable_mapping if step.variable_mapping.present?
    end
  end

  # Content#to_s renders through the app's Action Text layout (adds the
  # <div class="lexxy-content"> wrapper used for on-page display), so an
  # export built from #to_s round-trips through import into a body that's
  # wrapped again on the next export — nesting one layer deeper every cycle.
  # #to_html returns the stored fragment itself, which is what import expects
  # back.
  def rich_text_html(rich_text)
    rich_text&.body&.to_html.to_s
  end

  def serialize_transitions(step)
    step.transitions.map do |t|
      transition_data = { "target_uuid" => t.target_step.uuid }
      transition_data["condition"] = t.condition if t.condition.present?
      transition_data["label"] = t.label if t.label.present?
      transition_data
    end
  end
end
