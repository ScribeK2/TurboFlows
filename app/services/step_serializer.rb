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
        "instructions" => step.instructions&.body.to_s,
        "action_type" => step.action_type,
        "can_resolve" => step.can_resolve
      )
      data["output_fields"] = step.output_fields if step.output_fields.present?
    when Steps::Message
      data.merge!(
        "content" => step.content&.body.to_s,
        "can_resolve" => step.can_resolve
      )
    when Steps::Escalate
      data.merge!(
        "target_type" => step.target_type,
        "target_value" => step.target_value,
        "priority" => step.priority,
        "reason_required" => step.reason_required,
        "notes" => step.notes&.body.to_s
      )
    when Steps::Resolve
      data.merge!(
        "resolution_type" => step.resolution_type,
        "resolution_code" => step.resolution_code,
        "description" => step.description&.body.to_s,
        "notes_required" => step.notes_required,
        "survey_trigger" => step.survey_trigger
      )
    when Steps::Form
      data["instructions"] = step.instructions&.body.to_s
    when Steps::SubFlow
      data["target_workflow_id"] = step.sub_flow_workflow_id
      data["variable_mapping"] = step.variable_mapping if step.variable_mapping.present?
    end
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
