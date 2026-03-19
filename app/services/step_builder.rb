class StepBuilder
  STI_MAP = {
    "question" => Steps::Question,
    "action" => Steps::Action,
    "message" => Steps::Message,
    "escalate" => Steps::Escalate,
    "resolve" => Steps::Resolve,
    "sub_flow" => Steps::SubFlow
  }.freeze

  RICH_TEXT_FIELDS = {
    "instructions" => Steps::Action,
    "content" => Steps::Message,
    "notes" => Steps::Escalate
  }.freeze

  def self.call(workflow, steps_data, start_node_uuid: nil, replace: false)
    new(workflow, steps_data, start_node_uuid:, replace:).call
  end

  def self.sti_class_for(type)
    STI_MAP.fetch(type.to_s, Steps::Action)
  end

  def self.build_attrs(step_data, position)
    attrs = { title: step_data["title"], position: position }
    attrs[:position_x] = step_data["position_x"]&.to_i if step_data.key?("position_x")
    attrs[:position_y] = step_data["position_y"]&.to_i if step_data.key?("position_y")

    case step_data["type"].to_s
    when "question"
      attrs.merge!(question: step_data["question"], answer_type: step_data["answer_type"],
                   variable_name: step_data["variable_name"], options: step_data["options"])
    when "action"
      attrs.merge!(can_resolve: step_data["can_resolve"] || false, action_type: step_data["action_type"],
                   output_fields: step_data["output_fields"], jumps: step_data["jumps"])
    when "message"
      attrs[:can_resolve] = step_data["can_resolve"] || false
      attrs[:jumps] = step_data["jumps"]
    when "escalate"
      attrs.merge!(target_type: step_data["target_type"], target_value: step_data["target_value"],
                   priority: step_data["priority"], reason_required: step_data["reason_required"] || false)
    when "resolve"
      attrs.merge!(resolution_type: step_data["resolution_type"], resolution_code: step_data["resolution_code"],
                   notes_required: step_data["notes_required"] || false, survey_trigger: step_data["survey_trigger"] || false)
    when "sub_flow"
      attrs[:sub_flow_workflow_id] = step_data["target_workflow_id"]
      attrs[:variable_mapping] = step_data["variable_mapping"]
    end

    attrs
  end

  def initialize(workflow, steps_data, start_node_uuid: nil, replace: false)
    @workflow = workflow
    @steps_data = steps_data || []
    @start_node_uuid = start_node_uuid
    @replace = replace
  end

  def call
    return if @steps_data.blank?

    Workflow.transaction do
      destroy_existing_steps if @replace

      step_records = create_steps
      create_transitions(step_records)
      assign_start_step(step_records)
    end
  end

  private

  def destroy_existing_steps
    @workflow.steps.destroy_all
    @workflow.update_column(:start_step_id, nil)
  end

  def create_steps
    step_records = {}

    @steps_data.each_with_index do |step_data, index|
      step_data = normalize(step_data)
      uuid = step_data["id"].presence || SecureRandom.uuid
      sti_class = self.class.sti_class_for(step_data["type"].to_s)

      attrs = self.class.build_attrs(step_data, index).merge(
        workflow: @workflow,
        type: sti_class.name,
        uuid: uuid
      )

      step_record = Step.create!(attrs)
      assign_rich_text_fields(step_record, step_data)
      step_records[uuid] = step_record
    end

    step_records
  end

  def create_transitions(step_records)
    @steps_data.each do |step_data|
      step_data = normalize(step_data)
      source = step_records[step_data["id"]]
      next unless source

      transitions = step_data["transitions"]
      next unless transitions.is_a?(Array)

      transitions.each_with_index do |t, pos|
        t = normalize(t)
        target = step_records[t["target_uuid"]]
        next unless target

        Transition.create!(
          step: source,
          target_step: target,
          condition: t["condition"].presence,
          label: t["label"].presence,
          position: pos
        )
      end
    end
  end

  def assign_start_step(step_records)
    start_step = if @start_node_uuid.present?
                   step_records[@start_node_uuid]
                 else
                   step_records.values.first
                 end

    @workflow.update_column(:start_step_id, start_step.id) if start_step
  end

  def assign_rich_text_fields(step_record, step_data)
    RICH_TEXT_FIELDS.each do |field, klass|
      if step_record.is_a?(klass) && step_data[field].present?
        step_record.send(:"#{field}=", step_data[field])
        step_record.save!
      end
    end
  end

  def normalize(data)
    if data.respond_to?(:permit!)
      data.permit!.to_h
    elsif data.respond_to?(:stringify_keys)
      data.stringify_keys
    else
      data.to_h.stringify_keys
    end
  end
end
