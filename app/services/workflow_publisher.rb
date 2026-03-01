class WorkflowPublisher
  Result = Struct.new(:version, :error, keyword_init: true) do
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
    return Result.new(error: "Workflow has no steps") if @workflow.steps.blank?

    # Validate graph structure before publishing
    if @workflow.graph_mode?
      validator = GraphValidator.new(
        @workflow.graph_steps,
        @workflow.start_node_uuid || @workflow.steps.first&.dig("id")
      )
      unless validator.valid?
        return Result.new(error: validator.errors.join(", "))
      end
    end

    version = nil

    ActiveRecord::Base.transaction do
      next_number = (@workflow.versions.unscoped
                       .where(workflow_id: @workflow.id)
                       .maximum(:version_number) || 0) + 1

      version = WorkflowVersion.create!(
        workflow: @workflow,
        version_number: next_number,
        steps_snapshot: @workflow.steps.deep_dup,
        metadata_snapshot: build_metadata,
        published_by: @user,
        published_at: Time.current,
        changelog: @changelog
      )

      @workflow.update!(published_version: version)
    end

    Result.new(version:)
  rescue ActiveRecord::RecordInvalid => e
    Result.new(error: e.message)
  end

  private

  def build_metadata
    {
      "title" => @workflow.title,
      "description" => @workflow.description,
      "graph_mode" => @workflow.graph_mode,
      "start_node_uuid" => @workflow.start_node_uuid
    }
  end
end
