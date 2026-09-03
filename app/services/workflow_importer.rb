class WorkflowImporter
  Result = Data.define(:success, :workflow, :errors, :warnings, :incomplete_steps_count) do
    def success? = success
    def incomplete_steps? = incomplete_steps_count.to_i.positive?
  end

  def initialize(user, format:, content:, strict_report: nil)
    @user = user
    @format = format.to_sym
    @content = content
    @strict_report = strict_report
  end

  def call
    return import_strict(@strict_report) if @strict_report

    parser = create_parser

    workflow_data = parser.parse

    unless workflow_data
      parse_errors = parser.errors.any? ? parser.errors : ["Failed to parse file"]
      return failure(parse_errors, warnings: parser.warnings)
    end

    steps_data = workflow_data[:steps] || []
    incomplete_count = steps_data.count { |step| step["_import_incomplete"] }

    warnings = parser.warnings.dup
    warnings.concat(validate_parsed_graph(steps_data, workflow_data[:start_node_uuid])) if workflow_data[:graph_mode] != false

    placement = WorkflowPlacement.new(
      user: @user,
      groups: workflow_data[:groups],
      folder: workflow_data[:folder],
      tags: workflow_data[:tags]
    )
    placement_result = placement.resolve

    unless placement_result.valid?
      return failure(placement_result.errors.pluck(:message), warnings:)
    end

    workflow = @user.workflows.build(
      title: workflow_data[:title],
      description: workflow_data[:description] || "",
      graph_mode: workflow_data[:graph_mode] != false,
      is_public: false,
      status: "draft"
    )

    ActiveRecord::Base.transaction do
      unless workflow.save
        return Result.new(
          success: false,
          workflow:,
          errors: workflow.errors.full_messages,
          warnings:,
          incomplete_steps_count: incomplete_count
        )
      end

      create_ar_steps(workflow, steps_data, workflow_data[:start_node_uuid])

      # Must run before the update_all/reload pair below: apply! touches this
      # workflow row too (GroupWorkflow and Tagging both belong_to :workflow,
      # touch: true), and reload has to be the last write-absorbing step.
      placement.apply!(workflow)

      # `set_draft_expiration` runs `before_save, if: -> { draft? && (new_record?
      # || draft_expires_at.present?) }` (see Workflow), so it still stamps a
      # 7-day TTL on the `workflow.save` above — this is a new record — and
      # `CleanupDraftsJob` destroys anything past it with no check on title or
      # step count. An import is a real workflow, not an abandoned draft, so it
      # must carry no expiry. The guard means a later save won't re-stamp it
      # once `draft_expires_at` is nil, but this first save already ran the
      # callback and set it, so the row needs to be cleared once here — and
      # `update_column`/`update_columns` are off-limits, but `update_all` is the
      # same bypass at the relation level and is already how this codebase skips
      # callbacks for a deliberate column write (`Step::Positionable.insert_at`,
      # `HealthFixesController#add_resolve_after`). An in-memory
      # `draft_expires_at = nil` alone wouldn't hold: it never reaches the row,
      # so any later save shows the stamped value again.
      #
      # `update_all` also auto-increments `lock_version` when locking is
      # enabled, to stop a stale in-memory `#save` from clobbering it back —
      # but that leaves this loaded `workflow` object's cached `lock_version`
      # one behind the row. `has_rich_text :description` schedules a deferred
      # `touch` on `workflow` (Action Text's `belongs_to :record, touch: true`)
      # for commit time, and it raised `StaleObjectError` against that stale
      # cache until the `reload` below resynced it.
      Workflow.where(id: workflow.id).update_all(draft_expires_at: nil)
      workflow.reload
    end

    Result.new(
      success: true,
      workflow:,
      errors: [],
      warnings:,
      incomplete_steps_count: incomplete_count
    )
  rescue StandardError => e
    failure([e.message])
  end

  private

  # A strict report has already been parsed, normalised and validated — every
  # group resolved, every sub-flow target found, every graph rule checked — so
  # writing is all that is left. It reuses the placement the validator already
  # resolved rather than resolving twice, and shares create_ar_steps with the
  # lenient path because the normalized shape is deliberately the same.
  def import_strict(strict_report)
    raise ArgumentError, "strict_report must be valid" unless strict_report.valid?

    data = strict_report.workflow_data
    workflow = @user.workflows.build(
      title: data["title"],
      description: data["description"] || "",
      graph_mode: true,
      is_public: false,
      status: "draft"
    )

    ActiveRecord::Base.transaction do
      unless workflow.save
        return Result.new(success: false, workflow:, errors: workflow.errors.full_messages,
                          warnings: [], incomplete_steps_count: 0)
      end

      create_ar_steps(workflow, data["steps"], data["start_step_id"])
      strict_report.placement.apply!(workflow)
      Workflow.where(id: workflow.id).update_all(draft_expires_at: nil)
      workflow.reload
    end

    Result.new(success: true, workflow:, errors: [],
               warnings: strict_report.warnings.pluck(:message), incomplete_steps_count: 0)
  rescue StandardError => e
    failure([e.message])
  end

  def create_parser
    case @format
    when :json     then WorkflowParsers::JsonParser.new(@content)
    when :csv      then WorkflowParsers::CsvParser.new(@content)
    when :yaml     then WorkflowParsers::YamlParser.new(@content)
    when :markdown then WorkflowParsers::MarkdownParser.new(@content)
    else raise ArgumentError, "Unsupported format: #{@format}"
    end
  end

  # Create ActiveRecord Step and Transition records from parsed step hashes.
  # Runs after workflow is saved so we have a workflow_id.
  def create_ar_steps(workflow, steps_data, start_node_uuid = nil)
    return if steps_data.blank?

    uuid_to_step = {}

    # First pass: create all Step records
    steps_data.each_with_index do |step_hash, index|
      step_type = normalize_step_type(step_hash["type"])
      step_class = step_class_for(step_type)

      attrs = {
        workflow: workflow,
        uuid: step_hash["id"] || SecureRandom.uuid,
        position: index,
        title: step_hash["title"].presence || "Untitled Step",
        help_text: step_hash["help_text"],
        reference_url: step_hash["reference_url"]
      }

      # Type-specific attributes
      case step_type
      when "question"
        attrs[:question] = step_hash["question"] || ""
        attrs[:answer_type] = step_hash["answer_type"]
        attrs[:variable_name] = step_hash["variable_name"]
        attrs[:options] = step_hash["options"] if step_hash["options"].present?
        attrs[:can_resolve] = step_hash["can_resolve"]
      when "action"
        attrs[:action_type] = step_hash["action_type"]
        attrs[:can_resolve] = step_hash["can_resolve"]
        attrs[:output_fields] = step_hash["output_fields"] if step_hash["output_fields"].present?
        attrs[:jumps] = step_hash["jumps"] if step_hash["jumps"].present?
      when "message"
        attrs[:can_resolve] = step_hash["can_resolve"]
        attrs[:jumps] = step_hash["jumps"] if step_hash["jumps"].present?
      when "escalate"
        attrs[:target_type] = step_hash["target_type"]
        attrs[:target_value] = step_hash["target_value"].presence || step_hash["target_id"]
        attrs[:priority] = step_hash["priority"]
        attrs[:reason_required] = step_hash["reason_required"]
      when "resolve"
        attrs[:resolution_type] = step_hash["resolution_type"]
        attrs[:resolution_code] = step_hash["resolution_code"]
        attrs[:notes_required] = step_hash["notes_required"]
        attrs[:survey_trigger] = step_hash["survey_trigger"]
      when "sub_flow"
        attrs[:sub_flow_workflow_id] = step_hash["target_workflow_id"] if step_hash["target_workflow_id"].present?
        attrs[:variable_mapping] = step_hash["variable_mapping"] if step_hash["variable_mapping"].present?
      when "form"
        attrs[:options] = step_hash["options"] if step_hash["options"].present?
      end

      step = step_class.new(attrs)
      # Incomplete imported steps may lack required fields — skip validation
      if step_hash["_import_incomplete"]
        step.save!(validate: false)
      else
        step.save!
      end

      # Set rich text fields
      step.update(instructions: step_hash["instructions"]) if step_type == "action" && step_hash["instructions"].present?
      step.update(content: step_hash["content"]) if step_type == "message" && step_hash["content"].present?
      step.update(notes: step_hash["notes"].presence || step_hash["reason"]) if step_type == "escalate" && (step_hash["notes"].present? || step_hash["reason"].present?)
      step.update(description: step_hash["description"]) if step_type == "resolve" && step_hash["description"].present?
      step.update(instructions: step_hash["instructions"]) if step_type == "form" && step_hash["instructions"].present?

      uuid_to_step[attrs[:uuid]] = step
    end

    # Second pass: create Transition records
    steps_data.each do |step_hash|
      next unless step_hash["transitions"].is_a?(Array)

      source_uuid = step_hash["id"]
      source_step = uuid_to_step[source_uuid]
      next unless source_step

      step_hash["transitions"].each_with_index do |transition_hash, t_index|
        target_uuid = transition_hash["target_uuid"]
        target_step = uuid_to_step[target_uuid]
        next unless target_step

        Transition.create!(
          step: source_step,
          target_step: target_step,
          condition: transition_hash["condition"],
          label: transition_hash["label"],
          position: t_index
        )
      end
    end

    # Set start_step_id
    effective_start_uuid = start_node_uuid || steps_data.first&.dig("id")
    if effective_start_uuid && uuid_to_step[effective_start_uuid]
      workflow.update_columns(start_step_id: uuid_to_step[effective_start_uuid].id)
    end
  end

  def normalize_step_type(type)
    case type.to_s
    when "decision", "simple_decision" then "question"
    when "checkpoint" then "message"
    when "sub-flow" then "sub_flow"
    else type.to_s
    end
  end

  def step_class_for(type)
    case type
    when "question" then Steps::Question
    when "message"  then Steps::Message
    when "escalate" then Steps::Escalate
    when "resolve"  then Steps::Resolve
    when "sub_flow" then Steps::SubFlow
    when "form"     then Steps::Form
    else Steps::Action
    end
  end

  def validate_parsed_graph(steps_data, start_node_uuid)
    errors = []
    return errors if steps_data.blank?

    graph_steps = steps_data.each_with_object({}) do |step, hash|
      hash[step["id"]] = step if step.is_a?(Hash) && step["id"]
    end

    effective_start = start_node_uuid || steps_data.first&.dig("id")

    validator = GraphValidator.new(graph_steps, effective_start)
    unless validator.valid?
      validator.errors.each { |e| errors << "Graph validation: #{e}" }
    end

    errors
  rescue NameError
    []
  end

  def failure(errors, warnings: [])
    Result.new(
      success: false,
      workflow: nil,
      errors:,
      warnings:,
      incomplete_steps_count: 0
    )
  end
end
