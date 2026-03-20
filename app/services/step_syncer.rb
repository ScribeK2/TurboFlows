class StepSyncer
  Result = Data.define(:lock_version, :error) do
    def success?
      error.nil?
    end
  end

  def self.call(workflow, incoming_steps, start_node_uuid: nil, title: nil, description: nil)
    new(workflow, incoming_steps, start_node_uuid:, title:, description:).call
  end

  def initialize(workflow, incoming_steps, start_node_uuid: nil, title: nil, description: nil)
    @workflow = workflow
    @incoming_steps = (incoming_steps || []).map { |s| normalize(s) }
    @start_node_uuid = start_node_uuid
    @title = title
    @description = description
  end

  def call
    Workflow.transaction do
      update_workflow_fields
      existing_steps = load_existing_steps
      step_records = sync_steps(existing_steps)
      delete_removed_steps(existing_steps, step_records)
      reconcile_transitions(step_records)
      assign_start_step(step_records)

      @workflow.reload
      @workflow.touch
    end

    Result.new(lock_version: @workflow.reload.lock_version, error: nil)
  rescue ActiveRecord::RecordInvalid => e
    Result.new(lock_version: nil, error: e.message)
  end

  private

  def validate_has_resolve_step!(incoming_steps)
    return if @workflow.draft? # Allow drafts to save without Resolve steps

    has_resolve = incoming_steps.any? { |s| s["type"]&.downcase == "resolve" }
    unless has_resolve
      @workflow.errors.add(:base, "Workflow must contain at least one Resolve step")
      raise ActiveRecord::RecordInvalid, @workflow
    end
  end

  def update_workflow_fields
    @workflow.title = @title if @title.present?
    @workflow.description = @description if @description
  end

  def load_existing_steps
    Step.unscoped
        .where(workflow_id: @workflow.id)
        .includes(:transitions, :incoming_transitions)
        .index_by(&:uuid)
  end

  def sync_steps(existing_steps)
    step_records = {}

    @incoming_steps.each_with_index do |step_data, index|
      uuid = step_data["id"].presence || SecureRandom.uuid
      step_type = step_data["type"].to_s
      sti_class = StepBuilder.sti_class_for(step_type)

      if (existing = existing_steps[uuid])
        attrs = StepBuilder.build_attrs(step_data, index)
        existing.update!(attrs)
        assign_rich_text_fields(existing, step_data)
        step_records[uuid] = existing
      else
        attrs = StepBuilder.build_attrs(step_data, index).merge(
          workflow: @workflow,
          type: sti_class.name,
          uuid: uuid
        )
        step_record = Step.create!(attrs)
        assign_rich_text_fields(step_record, step_data)
        step_records[uuid] = step_record
      end
    end

    step_records
  end

  def delete_removed_steps(existing_steps, step_records)
    incoming_uuids = Set.new(step_records.keys)

    existing_steps.each do |uuid, step|
      unless incoming_uuids.include?(uuid)
        step.incoming_transitions.delete_all
        step.destroy!
      end
    end
  end

  def reconcile_transitions(step_records)
    @incoming_steps.each do |step_data|
      uuid = step_data["id"]
      source_step = step_records[uuid]
      next unless source_step

      incoming_transitions = (step_data["transitions"] || []).grep(Hash)

      desired = incoming_transitions.filter_map do |t|
        target = step_records[t["target_uuid"]]
        next nil unless target

        { target_step_id: target.id, condition: t["condition"].presence, label: t["label"].presence }
      end

      # Remove stale transitions
      existing_trans = Transition.unscoped.where(step_id: source_step.id).to_a
      existing_trans.each do |et|
        match = desired.find { |d| d[:target_step_id] == et.target_step_id && d[:condition] == et.condition }
        et.destroy! unless match
      end

      # Upsert desired transitions
      desired.each_with_index do |d, pos|
        t = Transition.find_or_initialize_by(
          step_id: source_step.id,
          target_step_id: d[:target_step_id],
          condition: d[:condition]
        )
        t.label = d[:label]
        t.position = pos
        t.save!
      end
    end
  end

  def assign_start_step(step_records)
    start_step = if @start_node_uuid.present?
                   step_records[@start_node_uuid]
                 else
                   step_records.values.first
                 end

    if start_step
      @workflow.update_column(:start_step_id, start_step.id)
    else
      @workflow.update_column(:start_step_id, nil)
    end
  end

  def assign_rich_text_fields(step_record, step_data)
    StepBuilder::RICH_TEXT_FIELDS.each do |field, klass|
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
