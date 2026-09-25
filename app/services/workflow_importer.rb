class WorkflowImporter
  # A bundle whose sub_flow references form a cycle. Carries SubflowValidator's
  # findings rather than one message, because it names each cycle it found.
  class CircularBundle < StandardError
    attr_reader :findings

    def initialize(findings)
      @findings = Array(findings)
      super(@findings.join("; "))
    end
  end

  # The validator promised an in-bundle title resolves and the importer could not
  # find it. Raised rather than skipped so the bundle rolls back loudly instead of
  # writing a sub_flow that points at nothing.
  class BundleTargetUnresolved < StandardError; end

  # Which SubflowValidator findings refuse an import outright. See
  # #circular_sub_flow_errors for why all three, and what went wrong with one.
  REFUSING_SUBFLOW_CODES = %i[circular_subflow max_depth_exceeded subflow_target_missing
                              no_resolve_across_workflows].freeze

  # The largest file any import path accepts: the upload page and the API.
  MAX_IMPORT_BYTES = 10.megabytes

  # `workflows` is every workflow this import created, in file order. The strict
  # dialect accepts a set in one file; the lenient formats are single-workflow by
  # nature, so they build a one-element array.
  #
  # `workflow` stays as the first, because most callers genuinely want "the
  # workflow this import made" and every lenient path has exactly one. Anything
  # that reports on the import must use `workflows`.
  Result = Data.define(:success, :workflows, :errors, :warnings, :incomplete_steps_count) do
    def success? = success
    def incomplete_steps? = incomplete_steps_count.to_i.positive?
    def workflow = workflows&.first
    def multiple? = workflows.to_a.size > 1
  end

  def initialize(user, format:, content:, strict_report: nil, api_token: nil)
    @user = user
    @format = format.to_sym
    @content = content
    @strict_report = strict_report
    @api_token = api_token
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

    # BaseParser#parse already ran GraphValidator over these same steps, with the
    # same start-node fallback, and recorded the result in parser.warnings. This
    # ran it a second time and concatenated the identical strings, so every graph
    # warning was reported twice — and the flash's "and N more..." counted the
    # duplicates.
    warnings = parser.warnings.dup

    placement = WorkflowPlacement.new(
      user: @user,
      groups: workflow_data[:groups],
      folder: workflow_data[:folder],
      tags: workflow_data[:tags]
    )
    placement_result = placement.resolve
    warnings.concat(placement_result.warnings.pluck(:message))

    unless placement_result.valid?
      return failure(placement_result.errors.pluck(:message), warnings:)
    end

    workflow = @user.workflows.build(
      title: workflow_data[:title],
      description: workflow_data[:description] || "",
      graph_mode: workflow_data[:graph_mode] != false,
      status: "draft"
    )

    ActiveRecord::Base.transaction do
      unless workflow.save
        return Result.new(
          success: false,
          workflows: [workflow],
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
      workflows: [workflow],
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
  # writing is all that is left. It reuses the placements the validator already
  # resolved rather than resolving twice, and shares create_ar_steps with the
  # lenient path because the normalized shape is deliberately the same.
  #
  # Every workflow in the file is created BEFORE any step is built.
  #
  # That ordering is what removes the need to sort the bundle by dependency: a
  # sub_flow step needs its target's id at the moment it is built, and after the
  # first pass every id in the bundle exists. A file where A runs B and B runs A
  # therefore writes fine; whether that is a legal *runtime* shape is
  # SubflowValidator's question, asked below once the graph is real.
  #
  # The whole bundle is one transaction. A file is a single deliverable, and half
  # an imported set is worse than none — the missing half is exactly what the
  # other half's sub_flow steps point at.
  def import_strict(strict_report)
    raise ArgumentError, "strict_report must be valid" unless strict_report.valid?

    data_set = strict_report.workflows_data
    workflows = []
    # Two variables, not one. Keying "did a save fail" off `save_errors.any?`
    # reported SUCCESS for a save that returned false without populating errors —
    # which is exactly what a `before_save` throwing :abort does, and Workflow
    # already runs one (`set_draft_expiration`). The result was a success Result
    # carrying records the transaction had just rolled back.
    save_failed = false
    save_errors = []

    # requires_new: so this is always a real transaction or savepoint. Joined to
    # an enclosing one it would be a no-op: `raise ActiveRecord::Rollback` would
    # be swallowed without rolling anything back, and the method would still
    # return failure — reporting a rollback that never happened. Nothing wraps
    # this today; the flag removes the class rather than relying on that.
    ActiveRecord::Base.transaction(requires_new: true) do
      workflows = data_set.map { |data| build_strict_workflow(data) }

      workflows.each do |workflow|
        next if workflow.save

        save_failed = true
        save_errors = workflow.errors.full_messages
        raise ActiveRecord::Rollback
      end

      titles = workflows.index_by { |workflow| workflow.title.to_s.strip.downcase }

      data_set.each_with_index do |data, index|
        resolve_bundle_sub_flow_targets(data["steps"], titles)
        create_ar_steps(workflows[index], data["steps"], data["start_step_id"])
        strict_report.placements[index].apply!(workflows[index])
      end

      Workflow.where(id: workflows.map(&:id)).update_all(draft_expires_at: nil)
      workflows.each(&:reload)

      circular = circular_sub_flow_errors(workflows)
      raise CircularBundle, circular if circular.any?
    end

    if save_failed
      return failure(save_errors.presence ||
                     ["A workflow in this file could not be saved, and reported no reason."])
    end

    Result.new(success: true, workflows:, errors: [],
               warnings: strict_report.warnings.pluck(:message), incomplete_steps_count: 0)
  rescue CircularBundle => e
    failure(e.findings)
  rescue StandardError => e
    failure([e.message])
  end

  def build_strict_workflow(data)
    @user.workflows.build(
      title: data["title"],
      description: data["description"] || "",
      graph_mode: true,
      status: "draft",
      api_token: @api_token
    )
  end

  # Bind the sub_flow targets the validator deliberately left as titles.
  #
  # It could not resolve them: an in-bundle target names a workflow that did not
  # exist when the file was checked. Anything pointing outside the bundle already
  # carries target_workflow_id and is untouched here.
  def resolve_bundle_sub_flow_targets(steps, titles_to_workflows)
    Array(steps).each do |step|
      next unless step["type"] == "sub_flow"

      # Only a title still present is this method's business. The validator
      # resolves an out-of-bundle target itself, setting target_workflow_id and
      # deleting the title, so a step arriving without one is already bound.
      raw_title = step["target_workflow_title"]
      next if raw_title.blank?

      target = titles_to_workflows[raw_title.to_s.strip.downcase]

      # Skipping quietly here is how a sub_flow imported bound to nothing while
      # the import reported success. The validator has already decided this title
      # names a workflow in this file, so a miss means the two disagree about
      # what the title IS — which happened for real: a JSON `true` compared as
      # "true" and saved as "t", because ActiveModel casts the column. That is a
      # bug, not a condition to step over, and it rolls the bundle back.
      unless target
        raise BundleTargetUnresolved,
              "sub_flow target #{step['target_workflow_title'].inspect} was accepted as " \
              "in-bundle but matches no workflow this import created " \
              "(have: #{titles_to_workflows.keys.inspect})"
      end

      step["target_workflow_id"] = target.id
      step.delete("target_workflow_title")
    end
  end

  # Sub-flow shape is a runtime question, so it is asked of the saved graph
  # rather than of the file. Inside one transaction, so a bad bundle writes
  # nothing.
  #
  # All three codes refuse. This filtered to `:circular_subflow` alone for a
  # while, because refusing a chain deeper than MAX_DEPTH looked like refusing a
  # legal file — MAX_WORKFLOWS_PER_FILE is 25 and MAX_DEPTH is 10, so a chain of
  # 11 validated clean and was then rolled back whole. The real defect there was
  # the *message*, which called a chain circular. Letting it through instead was
  # worse: `Workflow#validate_subflow_circular_references` copies every
  # save-blocking SubflowValidator finding onto the record on every save, so a
  # deep chain imported successfully and then could never be saved again, with no
  # fix available from the builder. Which findings block a save is now the
  # explicit `SubflowValidator::SAVE_BLOCKING_CODES` allowlist; `max_depth_exceeded`
  # is on it, so this rationale still holds. WorkflowHealthCheck files max-depth as a
  # :warning, which is the inconsistency — the model validation is the policy,
  # and it is hard.
  #
  # `:subflow_target_missing` refuses for a narrower reason: a published target
  # can be deleted between the preview request and the commit POST, and without
  # it the bundle writes a dangling sub_flow_workflow_id and reports success.
  def circular_sub_flow_errors(workflows)
    workflows.flat_map { |workflow| SubflowValidator.new(workflow.id).tap(&:valid?).findings }
             .select { |finding| REFUSING_SUBFLOW_CODES.include?(finding.code) }
             .map { |finding| subflow_refusal_message(finding) }
             .uniq
  end

  # SubflowValidator's own message is written for a single workflow being
  # edited. In an import the operator is holding a file, so each one says what
  # about the file is wrong and what to do to it.
  def subflow_refusal_message(finding)
    case finding.code
    when :max_depth_exceeded
      "Sub-flow nesting in this file is #{finding.details[:depth]} levels deep, and the limit is " \
      "#{SubflowValidator::MAX_DEPTH}. This is a chain, not a cycle — shorten it or split the file."
    when :subflow_target_missing
      "A sub-flow target outside this file (ID: #{finding.details[:target_workflow_id]}) no longer " \
      "exists. It may have been deleted since this file was checked; re-upload it."
    when :no_resolve_across_workflows
      "A workflow in this file never reaches a Resolve step, directly or through " \
      "any workflow it hands off to. Give it a reachable Resolve, or point a handoff " \
      "at a workflow that has one."
    else
      finding.message
    end
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
        # `key?`, not `.present?`. Every line around this one guards on presence,
        # and for a boolean whose meaningful value is `false` that reads as
        # "absent" — the field would be dropped and the column's default of true
        # would silently turn an imported handoff back into a returning
        # sub-flow. This is the fourth reader of the sub_flow field list, which
        # is what StepFieldMap exists to keep honest.
        attrs[:sub_flow_returns] = step_hash["sub_flow_returns"] if step_hash.key?("sub_flow_returns")
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

  def failure(errors, warnings: [])
    Result.new(
      success: false,
      workflows: [],
      errors:,
      warnings:,
      incomplete_steps_count: 0
    )
  end
end
