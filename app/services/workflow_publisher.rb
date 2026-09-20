class WorkflowPublisher
  Result = Data.define(:version, :error) do
    def success?
      error.nil?
    end
  end

  NO_AUDIENCE = "Choose who can see this workflow before publishing: pick at least one group in Details, " \
                "or Global for everyone signed in.".freeze

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
    validate_subflow_escapability!

    # Spec Q44. New workflows start with no groups (Q45), so without this a
    # forgotten choice publishes something only its owner and admins can see.
    # After the graph checks, so a broken workflow reports what is broken first.
    return Result.new(version: nil, error: NO_AUDIENCE) unless @workflow.group_workflows.exists?

    steps = build_ar_steps_snapshot
    metadata = build_metadata
    version = nil

    Workflow.transaction do
      version = unchanged_version(steps, metadata) || create_version!(steps, metadata)
      # The publish-readiness checks on Workflow run only inside this block.
      @workflow.while_publishing { @workflow.update!(published_version: version, status: "published") }
      release_old_snapshots!
    end

    Result.new(version:, error: nil)
  rescue ActiveRecord::RecordInvalid => e
    Result.new(version: nil, error: validation_message(e))
  end

  private

  # RecordInvalid#message is "Validation failed: " followed by every error's FULL
  # message, and `validate_subflow_steps` files on :steps — so a sentence that
  # already reads as one arrived as "Validation failed: Steps Sub-flow step
  # 'Hand to billing' requires a target workflow". An error on :steps is a whole
  # sentence already; any other attribute still needs its name, or "is too long
  # (maximum is 255 characters)" names nothing.
  #
  # The publisher's own raises (the graph check, :no_resolve_across_workflows)
  # pass a custom message and add nothing to the record, so they fall through to
  # that message untouched.
  def validation_message(error)
    errors = error.record&.errors
    return error.message if errors.blank?

    errors.map { |item| item.attribute == :steps ? item.message : item.full_message }.join(", ")
  end

  # Republishing without editing anything is not a new version. The previous row
  # already records that exact content, and writing a byte-identical ~9.5KB
  # snapshot beside it records nothing further.
  #
  # This compounds through WorkflowSetPublisher, which publishes a whole
  # dependency closure: a ten-workflow set republished for one change wrote ten
  # versions, nine of them identical to their predecessors.
  #
  # Unlike releasing a snapshot, skipping this write destroys nothing.
  def unchanged_version(steps, metadata)
    latest = @workflow.versions.newest_first.first
    latest if latest&.same_content_as?(steps, metadata)
  end

  def create_version!(steps, metadata)
    next_number = (@workflow.versions.maximum(:version_number) || 0) + 1

    WorkflowVersion.create!(
      workflow: @workflow,
      version_number: next_number,
      steps_snapshot: steps,
      metadata_snapshot: metadata,
      published_by: @user,
      published_at: Time.current,
      changelog: @changelog
    )
  end

  # Keep the last N restorable, release the rest. Done here rather than in a
  # nightly job because the rule is a count, and the only event that can push a
  # version past it is a publish — a scheduled scan would be hunting for work
  # this line already knows about, and one that finds nothing 364 days a year
  # gets deleted by someone who assumes it is dead.
  def release_old_snapshots!
    keep = @workflow.versions.newest_first.limit(WorkflowVersion.restore_limit).pluck(:id)
    @workflow.versions.restorable.where.not(id: keep).find_each(&:strip_snapshot!)
  end

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

  # Save validation deliberately ignores :no_resolve_across_workflows so a
  # half-built bundle stays editable, which means publish has to ask for itself.
  def validate_subflow_escapability!
    validator = SubflowValidator.new(@workflow.id)
    return if validator.valid?

    finding = validator.findings.find { |f| f.code == :no_resolve_across_workflows }
    return unless finding

    raise ActiveRecord::RecordInvalid.new(@workflow), finding.message
  end
end
