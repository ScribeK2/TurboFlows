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
  end

  def self.call(workflow)
    new(workflow).call
  end

  def initialize(workflow)
    @workflow = workflow
  end

  def call
    issues = Hash.new { |h, k| h[k] = [] }

    run_graph_validation(issues)
    run_subflow_validation(issues) if subflow_steps?
    run_step_validations(issues)

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

  def classify_graph_finding(finding, issues)
    case finding.code
    when :no_path_to_resolve
      # Attach to the step itself; the message already says a loop needs a way out.
      add_issue(issues, finding.step_uuid, :error, finding.message, fixable: false)

    when :transition_target_missing
      add_issue(issues, finding.step_uuid, :error, "Transition references a deleted step", fixable: false)

    when :unreachable_step
      add_issue(issues, finding.step_uuid, :warning, "Not reachable from the start step", fixable: false)

    when :no_terminal_nodes
      add_issue(issues, :workflow, :error, "Workflow has no ending steps", fixable: false)

    when :terminal_not_resolve
      add_issue(issues, finding.step_uuid, :error, "Terminal step is not a Resolve step",
                fixable: true, fix_type: "add_resolve_after")

      # :no_steps and :start_node_missing are unreachable from here — the caller
      # returns early on an empty graph, and start_uuid always falls back to a
      # real step. They are deliberately not surfaced, as before.
    end
  end

  def run_subflow_validation(issues)
    validator = SubflowValidator.new(@workflow.id)
    return if validator.valid?

    validator.findings.each do |finding|
      case finding.code
      when :circular_subflow
        add_issue(issues, :workflow, :error, "Circular sub-flow reference detected", fixable: false)
      when :max_depth_exceeded
        add_issue(issues, :workflow, :warning, "Sub-flow nesting exceeds #{SubflowValidator::MAX_DEPTH} levels", fixable: false)
      when :subflow_target_missing
        # SubflowValidator reasons about workflows, not steps, so it reports the
        # missing target's id and this maps it back to the step that names it.
        missing_id = finding.details[:target_workflow_id]
        subflow_step = steps_collection.find { |s| s.is_a?(Steps::SubFlow) && s.sub_flow_workflow_id == missing_id }
        add_issue(issues, subflow_step&.uuid || :workflow, :error, "Sub-flow references a missing workflow", fixable: false)
      end
    end
  end

  # Check for orphaned steps (no outgoing transitions, non-Resolve).
  # GraphValidator doesn't flag these directly as errors, but they're a common issue.
  def run_step_validations(issues)
    steps_collection.each do |step|
      next if step.is_a?(Steps::Resolve)

      if step.transitions.empty?
        add_issue(issues, step.uuid, :warning, "No outgoing connections — dead end",
                  fixable: true, fix_type: "connect_next")
      end

      if step.is_a?(Steps::Question) && step.title.blank?
        add_issue(issues, step.uuid, :warning, "Question text is required for publish", fixable: false)
      end

      if step.is_a?(Steps::SubFlow) && step.sub_flow_workflow_id.blank?
        add_issue(issues, step.uuid, :warning, "Sub-flow target is required for publish", fixable: false)
      end
    end
  end

  def subflow_steps?
    steps_collection.any?(Steps::SubFlow)
  end

  def add_issue(issues, uuid, severity, message, fixable: false, fix_type: nil)
    entry = { severity:, message:, fixable: }
    entry[:fix_type] = fix_type if fix_type
    issues[uuid.to_s] << entry
  end
end
