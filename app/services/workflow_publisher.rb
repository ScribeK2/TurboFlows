class WorkflowPublisher
  Result = Data.define(:version, :error) do
    def success?
      error.nil?
    end
  end

  def self.publish(workflow, user, changelog: nil)
    new(workflow, user, changelog:).publish
  end

  def initialize(workflow, user, changelog: nil)
    @workflow = workflow
    @user = user
    @changelog = changelog
  end

  def publish
    return Result.new(version: nil, error: "Workflow has no steps") unless @workflow.workflow_steps.any?

    # Validate graph structure before publishing
    validate_ar_graph! if @workflow.graph_mode?

    version = nil

    Workflow.transaction do
      next_number = (@workflow.versions.maximum(:version_number) || 0) + 1

      version = WorkflowVersion.create!(
        workflow: @workflow,
        version_number: next_number,
        steps_snapshot: build_ar_steps_snapshot,
        metadata_snapshot: build_metadata,
        published_by: @user,
        published_at: Time.current,
        changelog: @changelog
      )

      @workflow.update!(published_version: version)
    end

    Result.new(version:, error: nil)
  rescue ActiveRecord::RecordInvalid => e
    Result.new(version: nil, error: e.message)
  end

  private

  def build_metadata
    {
      "title" => @workflow.title,
      "description" => @workflow.description_text,
      "graph_mode" => @workflow.graph_mode,
      "start_node_uuid" => @workflow.start_step&.uuid
    }
  end

  # Build steps snapshot from AR Step records
  def build_ar_steps_snapshot
    @workflow.workflow_steps.includes(:transitions).map do |step|
      data = {
        "id" => step.uuid,
        "type" => step.type.demodulize.underscore,
        "title" => step.title,
        "position" => step.position
      }

      case step
      when Steps::Question
        data["question"] = step.question
        data["answer_type"] = step.answer_type
        data["variable_name"] = step.variable_name
        data["options"] = step.options if step.options.present?
        data["can_resolve"] = step.can_resolve
      when Steps::Action
        data["instructions"] = step.instructions&.body&.to_s || ""
        data["action_type"] = step.action_type
        data["can_resolve"] = step.can_resolve
        data["output_fields"] = step.output_fields if step.output_fields.present?
      when Steps::Message
        data["content"] = step.content&.body&.to_s || ""
        data["can_resolve"] = step.can_resolve
      when Steps::Escalate
        data["target_type"] = step.target_type
        data["target_value"] = step.target_value
        data["priority"] = step.priority
        data["reason_required"] = step.reason_required
        data["notes"] = step.notes&.body&.to_s || ""
      when Steps::Resolve
        data["resolution_type"] = step.resolution_type
        data["resolution_code"] = step.resolution_code
        data["notes_required"] = step.notes_required
        data["survey_trigger"] = step.survey_trigger
      when Steps::SubFlow
        data["target_workflow_id"] = step.sub_flow_workflow_id
        data["variable_mapping"] = step.variable_mapping if step.variable_mapping.present?
      end

      data["transitions"] = step.transitions.map do |t|
        transition_data = { "target_uuid" => t.target_step.uuid }
        transition_data["condition"] = t.condition if t.condition.present?
        transition_data["label"] = t.label if t.label.present?
        transition_data
      end

      data
    end
  end

  # Validate graph structure from AR steps
  def validate_ar_graph!
    graph_steps = {}
    @workflow.workflow_steps.includes(:transitions).each do |step|
      step_hash = {
        "id" => step.uuid,
        "type" => step.type.demodulize.underscore,
        "title" => step.title,
        "transitions" => step.transitions.map { |t| { "target_uuid" => t.target_step.uuid, "condition" => t.condition } }
      }
      graph_steps[step.uuid] = step_hash
    end

    start_uuid = @workflow.start_step&.uuid || @workflow.workflow_steps.first&.uuid
    validator = GraphValidator.new(graph_steps, start_uuid)

    unless validator.valid?
      raise ActiveRecord::RecordInvalid.new(@workflow), validator.errors.join(", ")
    end
  end
end
