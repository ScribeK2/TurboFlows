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
    return Result.new(version: nil, error: "Workflow has no steps") unless @workflow.steps.any?

    # Validate graph structure before publishing
    validate_ar_graph!

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

      @workflow.update!(published_version: version, status: "published")
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

  def build_ar_steps_snapshot
    StepSerializer.call(@workflow)
  end

  # Validate graph structure from AR steps
  def validate_ar_graph!
    start_uuid = @workflow.start_step&.uuid || @workflow.steps.first&.uuid
    validator = GraphValidator.new(@workflow.validation_graph_hash, start_uuid)

    unless validator.valid?
      raise ActiveRecord::RecordInvalid.new(@workflow), validator.errors.join(", ")
    end
  end
end
