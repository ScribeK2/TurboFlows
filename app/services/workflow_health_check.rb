# Runs graph validation, sub-flow validation, and step-level checks against
# a workflow and returns per-step health issues with severity and fix metadata.
#
# Usage:
#   result = WorkflowHealthCheck.call(workflow)
#   result.issues      # => { "uuid-1" => [{ severity: :error, ... }], ... }
#   result.summary     # => { errors: 2, warnings: 1, total: 3 }
#   result.clean?      # => false
class WorkflowHealthCheck
  Result = Data.define(:issues, :summary) do
    def clean?
      summary[:total].zero?
    end

    # The issues a publish would refuse, whatever their severity.
    def publish_blockers
      issues.values.flatten.select { |issue| WorkflowHealthCheck::PUBLISH_BLOCKING_CODES.include?(issue[:code]) }
    end
  end

  def self.call(workflow)
    new(workflow).call
  end

  # A step with no outgoing transitions produces three findings that are the same
  # sentence: "has no path to a Resolve step", "terminal step is not a Resolve
  # step", and "no outgoing connections". A Question and a Resolve with no line
  # between them reported four issues across two severities, which reads as a
  # badly broken workflow rather than "you have not drawn the connection yet".
  #
  # Nothing is hidden. The remaining issue is still an error, still blocks the
  # publish, and still carries the Fix. The findings dropped are true only
  # *because* the step has no transitions, which is what the survivor says.
  RESTATED_BY_NO_TRANSITIONS = %i[no_path_to_resolve terminal_not_resolve].freeze

  # What WorkflowPublisher and Workflow#while_publishing refuse. An allowlist, like
  # SubflowValidator::SAVE_BLOCKING_CODES, and not a severity: no_audience and the
  # sub-flow codes are warnings, and each of them blocks a publish. Every code this
  # check can report is in exactly one of these two lists, which a test enforces.
  PUBLISH_BLOCKING_CODES = %i[
    no_steps start_node_missing transition_target_missing unreachable_step
    no_terminal_nodes terminal_not_resolve no_path_to_resolve no_outgoing_transitions
    circular_subflow subflow_target_missing subflow_target_required max_depth_exceeded
    no_resolve_across_workflows no_audience
  ].freeze

  # subflow_target_unpublished does not block: WorkflowSetPublisher publishes the
  # linked drafts together. The rest only make an export unreadable.
  NON_BLOCKING_CODES = %i[
    subflow_target_unpublished title_required question_text_required
    handoff_has_transitions select_options_required form_field_incomplete
  ].freeze

  def collapse_no_transition_restatements(issues)
    issues.each_value do |step_issues|
      next unless step_issues.any? { |i| i[:code] == :no_outgoing_transitions }

      step_issues.reject! { |i| RESTATED_BY_NO_TRANSITIONS.include?(i[:code]) }
    end
  end

  # Build the graph hash from already-loaded AR records to avoid duplicate queries.
  # BaseController#eager_load_steps preloads transitions + target_step.
  def build_graph_hash
    GraphHashBuilder.call(steps_collection)
  end

  def steps_collection
    @steps_collection ||= @workflow.steps.includes(transitions: :target_step).to_a
  end

  def start_uuid
    @start_uuid ||= @workflow.start_step&.uuid || steps_collection.first&.uuid
  end

  # id => title, for every sub_flow target of this workflow that is still a
  # draft. One query for the whole step list rather than one per sub_flow step.
  def unpublished_subflow_targets
    @unpublished_subflow_targets ||= begin
      target_ids = steps_collection.filter_map { |s| s.sub_flow_workflow_id if s.is_a?(Steps::SubFlow) }
      target_ids.any? ? Workflow.where(id: target_ids, status: "draft").pluck(:id, :title).to_h : {}
    end
  end

  # Translate GraphValidator findings into per-step issues.
  #
  # Severity, panel wording and fix metadata are decided HERE, not in the
  # validator: the same finding is a warning in this panel and a hard failure at
  # publish, so the policy belongs to the consumer. The validator's job is to say
  # what failed and on which step.
  def run_graph_validation(issues)
    graph_hash = build_graph_hash
    return if graph_hash.empty?

    validator = GraphValidator.new(graph_hash, start_uuid)
    return if validator.valid?

    validator.findings.each { |finding| classify_graph_finding(finding, issues) }
  end

  # How each graph finding reads in the panel. Severity is deliberately absent:
  # WorkflowPublisher blocks on GraphValidator#valid?, which is just
  # "@findings.any?", so every finding the validator produces stops a publish and
  # all of them are errors. This table decides wording and fixability only.
  #
  # It used to be a case statement that also chose a severity per code, and
  # :unreachable_step had been given :warning. The builder therefore showed no
  # Publish badge and listed "every step can reach a Resolve step" under
  # Passing, and then publish refused with "Step 'X' is not reachable from the
  # start node". One validator, two opinions. A code added to GraphValidator now
  # surfaces as an error without anyone remembering to classify it.
  GRAPH_FINDING_PRESENTATION = {
    transition_target_missing: { message: "Transition references a deleted step" },
    unreachable_step: { message: "Not reachable from the start step" },
    no_terminal_nodes: { message: "Workflow has no ending steps", on: :workflow },
    terminal_not_resolve: { message: "Terminal step is not a Resolve step",
                            fixable: true, fix_type: "add_resolve_after" }
    # :no_path_to_resolve falls through to the validator's own message, which
    # already names the step and what is missing.
    #
    # :no_steps and :start_node_missing are unreachable from here — the caller
    # returns early on an empty graph, and start_uuid always falls back to a real
    # step. They are deliberately not surfaced, as before.
  }.freeze

  def initialize(workflow)
    @workflow = workflow
  end

  def call
    issues = Hash.new { |h, k| h[k] = [] }

    run_audience_check(issues)
    run_graph_validation(issues)
    run_subflow_validation(issues) if subflow_steps?
    run_step_validations(issues)
    collapse_no_transition_restatements(issues)

    summary = { errors: 0, warnings: 0, total: 0 }
    issues.each_value do |step_issues|
      step_issues.each do |issue|
        summary[:total] += 1
        if issue[:severity] == :error
          summary[:errors] += 1
        else
          summary[:warnings] += 1
        end
      end
    end

    Result.new(issues: issues.to_h, summary:)
  end

  private

  # First, so it heads the panel: the one problem a finished graph can still
  # have, and the easiest to forget (spec Q41, Q44). A warning, like
  # :no_resolve_across_workflows — publish refuses it, but every new draft
  # starts this way and an error on an empty builder would say nothing useful.
  def run_audience_check(issues)
    return if @workflow.group_workflows.exists?

    add_issue(issues, :workflow, :warning,
              "No audience yet — only you and admins can see this. Choose groups, or Global, in Details.",
              fixable: false, code: :no_audience)
  end

  def classify_graph_finding(finding, issues)
    presentation = GRAPH_FINDING_PRESENTATION.fetch(finding.code, {})
    target = presentation[:on] == :workflow ? :workflow : finding.step_uuid

    add_issue(issues, target, :error, presentation.fetch(:message, finding.message),
              fixable: presentation.fetch(:fixable, false),
              fix_type: presentation[:fix_type],
              code: finding.code)
  end

  def run_subflow_validation(issues)
    validator = SubflowValidator.new(@workflow.id)
    return if validator.valid?

    validator.findings.each do |finding|
      case finding.code
      when :circular_subflow
        add_issue(issues, :workflow, :error, "Circular sub-flow reference detected",
                  fixable: false, code: finding.code)
      when :max_depth_exceeded
        add_issue(issues, :workflow, :warning, "Sub-flow nesting exceeds #{SubflowValidator::MAX_DEPTH} levels",
                  fixable: false, code: finding.code)
      when :subflow_target_missing
        # SubflowValidator reasons about workflows, not steps, so it reports the
        # missing target's id and this maps it back to the step that names it.
        missing_id = finding.details[:target_workflow_id]
        subflow_step = steps_collection.find { |s| s.is_a?(Steps::SubFlow) && s.sub_flow_workflow_id == missing_id }
        add_issue(issues, subflow_step&.uuid || :workflow, :error, "Sub-flow references a missing workflow",
                  fixable: false, code: finding.code)
      when :no_resolve_across_workflows
        # A warning, not an error: a bundle lands as drafts referencing drafts
        # and is wired leaf-first, so this is the normal state of half-built
        # work. Publish and import commit refuse it; the builder just shows it.
        add_issue(issues, :workflow, :warning,
                  "No path to a Resolve step from this workflow or any it hands off to",
                  fixable: false, code: finding.code)
      end
    end
  end

  # Check for orphaned steps (no outgoing transitions, non-Resolve).
  # GraphValidator doesn't flag these directly as errors, but they're a common issue.
  def run_step_validations(issues)
    steps_collection.each do |step|
      next if step.is_a?(Steps::Resolve)

      # A handoff has no outgoing connections by design — that is what makes it a
      # tail call rather than an edge. Flagging it offered a `connect_next` Fix
      # button that would ADD a transition and quietly turn it back into an
      # ordinary sub-flow. `add_resolve_after` stopped firing for free once
      # GraphValidator learned the flag, but this check is independent of the
      # validator and had to be told separately.
      if step.transitions.empty? && !handoff?(step)
        # An error, not a warning: a non-Resolve step with no outgoing
        # transitions is a terminal that is not a Resolve, which is exactly what
        # publish refuses. It also *replaces* the graph findings for this step —
        # see collapse_no_transition_restatements.
        # `add_resolve_after`, not `connect_next`. Since this issue now stands in
        # for the terminal-not-Resolve finding too, its Fix has to work when
        # there is no next step to connect to — `connect_next` answers that with
        # "No next step to connect to." `add_resolve_after` wires the step to a
        # Resolve that already exists, or creates one, so it is right either way.
        add_issue(issues, step.uuid, :error, "No outgoing connections — the run ends here without resolving",
                  fixable: true, fix_type: "add_resolve_after", code: :no_outgoing_transitions)
      end

      # Both are warnings, not publish refusals, but the import schema requires
      # both fields, so an export carrying either blank is refused on the way
      # back in (see workflow_export_import_round_trip_test).
      if step.title.blank?
        add_issue(issues, step.uuid, :warning, "Step has no title, so its export is refused",
                  fixable: false, code: :title_required)
      end

      # The runner shows the step title when the question is blank, so the run
      # still works. This read step.title until 2026-09-10, so a new Question
      # was never flagged.
      if step.is_a?(Steps::Question) && step.question.blank?
        add_issue(issues, step.uuid, :warning,
                  "Question text is empty: the agent sees the step title instead, and its export is refused",
                  fixable: false, code: :question_text_required)
      end

      # A handoff ends the workflow, so a transition leaving it goes nowhere: the
      # runtime ignores it, but export emits it and the strict path then refuses
      # the file with `unexpected_transitions`. Authorable by connecting a
      # sub-flow first and unticking "come back" afterwards, which clears
      # nothing.
      if handoff?(step) && step.transitions.any?
        add_issue(issues, step.uuid, :warning,
                  "This step hands the run over, so its outgoing connection is never used " \
                  "— and it makes the exported file unreadable. Remove the connection.",
                  fixable: false, code: :handoff_has_transitions)
      end

      if step.is_a?(Steps::SubFlow) && step.sub_flow_workflow_id.blank?
        add_issue(issues, step.uuid, :warning, "Sub-flow target is required for publish",
                  fixable: false, code: :subflow_target_required)
      end

      # An unpublished target is legal to save and legal to run — it only blocks
      # publish. This is the whole signpost for a bundle: a file's workflows
      # reference each other and all land as drafts, so publishing them is
      # leaf-first, and without this the operator meets that ordering as a
      # validation failure on the publish button with nothing having said so.
      if step.is_a?(Steps::SubFlow) && unpublished_subflow_targets.key?(step.sub_flow_workflow_id)
        add_issue(issues, step.uuid, :warning,
                  "Target workflow #{unpublished_subflow_targets[step.sub_flow_workflow_id].inspect} " \
                  "is still a draft — publish it before publishing this one",
                  fixable: false, code: :subflow_target_unpublished)
      end

      next unless step.is_a?(Steps::Form)

      # A select field with no choices renders a dropdown the agent cannot
      # answer. Nothing could write `select_options` before 2026-09-04, so every
      # select authored until then is in this state — and it is not only a live
      # runner problem: an export carries schema_version, so it re-imports down
      # the strict path, where StrictImportValidator refuses it outright. This
      # is where an operator finds out which workflows to fix.
      step.select_fields_without_choices.each do |field|
        label = field["label"].presence || field["name"]
        add_issue(issues, step.uuid, :warning,
                  "Select field #{label.to_s.inspect} lists no choices — it renders an empty dropdown",
                  fixable: false, code: :select_options_required)
      end

      # The builder no longer lets the browser refuse a save over an empty name
      # or label, so this is where an author finds a field they started and
      # didn't finish. The runner posts each answer as answer[<name>], so a
      # field with no name has nothing to record its answer under.
      step.incomplete_fields.each do |field|
        named = field["label"].presence || field["name"]
        add_issue(issues, step.uuid, :warning,
                  "Form field #{named.to_s.inspect} needs both a name and a label: " \
                  "its answer is recorded under the name",
                  fixable: false, code: :form_field_incomplete)
      end
    end
  end

  def subflow_steps?
    steps_collection.any?(Steps::SubFlow)
  end

  # A sub_flow that hands the run over instead of returning to this workflow.
  def handoff?(step)
    step.is_a?(Steps::SubFlow) && !step.sub_flow_returns
  end

  # code: a stable symbol naming the problem, always present now that every
  # check the health panel's passing-checks list depends on plumbs one through
  # — either the originating GraphValidator/SubflowValidator finding code
  # (:unreachable_step, :no_path_to_resolve, :terminal_not_resolve,
  # :circular_subflow, :max_depth_exceeded, :subflow_target_missing) or one
  # coined here for a step-level check with no validator finding behind it
  # (:title_required, :question_text_required, :subflow_target_required,
  # :select_options_required, :form_field_incomplete). Lets consumers key on
  # a stable symbol instead of matching substrings of human-readable `message`
  # text — see the passing-checks section of _health_panel_inner.
  def add_issue(issues, uuid, severity, message, fixable: false, fix_type: nil, code: nil)
    entry = { severity:, message:, fixable: }
    entry[:fix_type] = fix_type if fix_type
    entry[:code] = code if code
    issues[uuid.to_s] << entry
  end
end
