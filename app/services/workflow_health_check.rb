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
    run_subflow_validation(issues) if has_subflow_steps?
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
    hash = {}
    steps_collection.each do |step|
      hash[step.uuid] = {
        "id" => step.uuid,
        "type" => step.type.demodulize.underscore,
        "title" => step.title,
        "transitions" => step.transitions.map { |t| { "target_uuid" => t.target_step&.uuid, "condition" => t.condition } }
      }
    end
    hash
  end

  def steps_collection
    @steps_collection ||= @workflow.steps.includes(transitions: :target_step).to_a
  end

  def start_uuid
    @start_uuid ||= @workflow.start_step&.uuid || steps_collection.first&.uuid
  end

  # Map GraphValidator error strings back to step UUIDs and classify severity.
  def run_graph_validation(issues)
    graph_hash = build_graph_hash
    return if graph_hash.empty?

    validator = GraphValidator.new(graph_hash, start_uuid)
    return if validator.valid?

    validator.errors.each do |error|
      classify_graph_error(error, issues, graph_hash)
    end
  end

  def classify_graph_error(error, issues, graph_hash)
    case error
    when /Cycle detected: (.+)/
      cycle_titles = $1.split(" -> ")
      # Attach to the first step in the cycle
      uuid = find_uuid_by_title(cycle_titles.first, graph_hash)
      add_issue(issues, uuid, :error, error, fixable: false)

    when /References non-existent step ID/
      uuid = extract_step_uuid_from_error(error, graph_hash)
      add_issue(issues, uuid, :error, "Transition references a deleted step", fixable: false)

    when /not reachable from the start node/
      title = error.match(/Step '(.+)' is not reachable/)&.[](1)
      uuid = find_uuid_by_title(title, graph_hash)
      add_issue(issues, uuid, :warning, "Not reachable from the start step", fixable: false)

    when /No terminal nodes found/
      add_issue(issues, :workflow, :error, "Workflow has no ending steps", fixable: false)

    when /Terminal node '(.+)' is not a Resolve step/
      title = $1
      uuid = find_uuid_by_title(title, graph_hash)
      add_issue(issues, uuid, :error, "Terminal step is not a Resolve step", fixable: true, fix_type: "add_resolve_after")

    when /Workflow has no steps/
      # No steps = nothing to show warnings on
    end
  end

  def run_subflow_validation(issues)
    validator = SubflowValidator.new(@workflow.id)
    return if validator.valid?

    validator.errors.each do |error|
      case error
      when /Circular sub-flow reference/
        add_issue(issues, :workflow, :error, "Circular sub-flow reference detected", fixable: false)
      when /exceeds maximum depth/
        add_issue(issues, :workflow, :warning, "Sub-flow nesting exceeds 10 levels", fixable: false)
      when /non-existent workflow.*ID: (\d+)/
        # Find the sub-flow step referencing this missing workflow
        missing_id = $1.to_i
        subflow_step = steps_collection.find { |s| s.is_a?(Steps::SubFlow) && s.sub_flow_workflow_id == missing_id }
        uuid = subflow_step&.uuid || :workflow
        add_issue(issues, uuid, :error, "Sub-flow references a missing workflow", fixable: false)
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

  def has_subflow_steps?
    steps_collection.any? { |s| s.is_a?(Steps::SubFlow) }
  end

  def add_issue(issues, uuid, severity, message, fixable: false, fix_type: nil)
    entry = { severity:, message:, fixable: }
    entry[:fix_type] = fix_type if fix_type
    issues[uuid.to_s] << entry
  end

  def find_uuid_by_title(title, graph_hash)
    match = graph_hash.find { |_uuid, step| step["title"] == title }
    match ? match[0] : :workflow
  end

  def extract_step_uuid_from_error(error, graph_hash)
    # Error format: "Step 'Title', Transition N: References non-existent step ID: uuid"
    title = error.match(/Step '(.+?)',/)&.[](1)
    find_uuid_by_title(title, graph_hash)
  end
end
