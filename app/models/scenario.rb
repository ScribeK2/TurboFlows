class Scenario < ApplicationRecord
  include ScenarioExecution

  belongs_to :workflow
  belongs_to :user

  # Parent/child scenario associations for sub-flows
  belongs_to :parent_scenario, class_name: 'Scenario', optional: true
  has_many :child_scenarios, class_name: 'Scenario', foreign_key: 'parent_scenario_id', inverse_of: :parent_scenario, dependent: :destroy
  has_many :step_responses, dependent: :destroy

  # String-backed enum — maps to existing column values with no migration needed.
  # :timed_out maps to DB "timeout", :errored maps to DB "error" to avoid Ruby naming conflicts.
  enum :status, {
    active: "active",
    completed: "completed",
    stopped: "stopped",
    timed_out: "timeout",
    errored: "error",
    awaiting_subflow: "awaiting_subflow"
  }, default: "active"

  # Keep STATUSES for backward compatibility
  STATUSES = %w[active completed stopped timeout error awaiting_subflow].freeze

  # End states: the run is over and its outcome is settled.
  TERMINAL_STATUSES = %w[completed stopped timeout error].freeze

  # Scenario limits to prevent infinite loops and DoS
  MAX_ITERATIONS = ENV.fetch("SCENARIO_MAX_ITERATIONS", 1000).to_i
  MAX_CONDITION_DEPTH = 50 # Max nested condition evaluations per step

  # Cap on free text stored on an execution_path entry (snapshot values and the
  # captured step body). An action's instructions is the largest free-text field
  # in the system and these entries live in a json column.
  ENTRY_TEXT_LIMIT = 2000

  # Inputs the runner controllers stash for one step, which that step consumes.
  # They are deliberately absent from an entry's undo log: backing out of an
  # escalate step must not hand the next one a reason the user already spent.
  TRANSIENT_INPUT_KEYS = %w[escalation_reason resolution_notes].freeze

  # Retention periods for cleanup (days)
  def self.simulation_retention_days
    ENV.fetch("SCENARIO_RETENTION_SIMULATION_DAYS", 7).to_i
  end

  def self.live_retention_days
    ENV.fetch("SCENARIO_RETENTION_LIVE_DAYS", 90).to_i
  end

  # Custom error class
  class ScenarioIterationLimit < StandardError; end

  # JSON columns - automatically serialized/deserialized

  # Initialize execution_path and results as empty arrays/hashes if needed
  before_save :initialize_execution_data

  # Analytics tracking
  before_create :set_started_at

  # Valid purposes
  PURPOSES = %w[simulation live].freeze
  validates :purpose, inclusion: { in: PURPOSES }, allow_nil: false

  # Valid outcomes
  OUTCOMES = %w[completed resolved escalated abandoned error].freeze
  validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true

  # Cleanup scopes
  scope :terminal, -> { where(status: TERMINAL_STATUSES) }

  scope :stale_simulations, lambda {
    terminal.where(purpose: "simulation")
            .where(completed_at: ...simulation_retention_days.days.ago)
  }

  scope :stale_live, lambda {
    terminal.where(purpose: "live")
            .where(completed_at: ...live_retention_days.days.ago)
  }

  # Deletes stale scenarios in batches of 5,000. Returns the total count removed.
  # Uses delete_all for performance — bypasses callbacks and dependent: :destroy.
  # step_responses are cascade-deleted at the DB level (FK ON DELETE CASCADE).
  # Child scenarios are deleted explicitly (parent FK is ON DELETE NULLIFY).
  def self.cleanup_stale
    total = 0
    [stale_simulations, stale_live].each do |scope|
      loop do
        batch_ids = scope.limit(5000).pluck(:id)
        break if batch_ids.empty?

        where(parent_scenario_id: batch_ids).delete_all
        where(id: batch_ids).delete_all
        total += batch_ids.size
      end
    end
    total
  end

  # Enum handles status validation automatically

  # Track iteration count for step-by-step processing
  attr_accessor :iteration_count

  # Pending timestamp set when a step is displayed, consumed when path entry is built
  attr_accessor :step_started_at_pending

  # The variable bag as it stood before the current step ran, so append_path_entry
  # can diff against it. Mirrors step_started_at_pending: per-step state that has
  # to reach the entry builder without becoming a column.
  attr_accessor :results_before_step, :inputs_before_step

  def initialize_execution_data
    self.execution_path ||= []
    self.results ||= {}
    self.inputs ||= {}
  end

  # All workflows are now graph mode
  def graph_mode?
    true
  end

  # Get the current step via UUID lookup
  # Returns an AR Step object or nil
  def current_step
    return nil unless workflow&.steps&.any?
    return nil if current_node_uuid.blank?

    workflow.steps.find_by(uuid: current_node_uuid)
  end

  # Get the current step UUID
  def current_step_uuid
    current_node_uuid
  end

  # Get the active child scenario (if any)
  def active_child_scenario
    child_scenarios.find_by(status: %w[active awaiting_subflow])
  end

  # Walk up the parent chain to find the top-level scenario.
  # Used to reference the root workflow during seamless sub-flow traversal.
  def root_scenario
    current = self
    current = current.parent_scenario while current.parent_scenario.present?
    current
  end

  # The top-level workflow — always the root parent's workflow.
  def root_workflow
    root_scenario.workflow
  end

  # Check if scenario is complete
  def complete?
    return true if completed?
    return true if stopped?
    return false if awaiting_subflow?
    return true unless workflow&.steps&.any?

    # Complete when no current node
    current_node_uuid.nil? && !active?
  end

  # Stop the workflow execution.
  #
  # A run spans a whole scenario tree once sub-flows are involved, so stopping
  # one frame of it is not stopping the run: cancelling inside a sub-flow used
  # to leave the parent sitting in awaiting_subflow until the retention job
  # reaped it. Stop the root and every unfinished scenario beneath it, leaving
  # already-terminal children with the outcome they earned.
  def stop!(step_index = nil)
    transaction do
      stop_frame!(step_index)
      root = root_scenario
      root.stop_frame! unless root == self
      root.unfinished_descendants.each(&:stop_frame!)
    end
  end

  # True once the run reached an end state and its outcome is settled.
  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  # Stops this scenario alone. Use stop! unless you specifically mean one frame.
  #
  # Terminal scenarios are left alone: a POST to the stop route for a run that
  # already completed would otherwise flip it to stopped and overwrite its
  # outcome with "abandoned", destroying the record of a finished run.
  def stop_frame!(step_index = nil)
    return if terminal?

    record_completion("abandoned")
    update!(
      status: 'stopped',
      stopped_at_step_index: step_index || current_step_index
    )
  end

  # Every scenario below this one that is still running.
  def unfinished_descendants
    child_scenarios.where(status: %w[active awaiting_subflow]).flat_map do |child|
      [child] + child.unfinished_descendants
    end
  end

  # Process a single step and advance.
  #
  # Returns a ScenarioStepProcessor::Outcome describing what happened, so a
  # caller can tell "moved on" from "refused, and here is why" — a distinction
  # the old boolean could not carry.
  #
  # A :blocked outcome leaves this record untouched: nothing is saved, so a
  # refused attempt adds no entry to the execution path and no visit to the
  # trail. Raises ScenarioIterationLimit if max iterations exceeded.
  def process_step(answer = nil, resolved_here: false)
    return ScenarioStepProcessor::Outcome.halted(:not_runnable) if complete? || stopped? || timed_out? || errored?
    return subflow_completion_outcome if awaiting_subflow?

    step = current_step
    return ScenarioStepProcessor::Outcome.halted(:no_step) unless step

    # Idempotency guard: prevent re-processing the same non-interactive step.
    # Question and form steps are excluded because users can legitimately re-answer after back navigation.
    if execution_path.present? && %w[question form].exclude?(step.step_type)
      last_entry = execution_path.last
      return ScenarioStepProcessor::Outcome.halted(:already_processed) if last_entry&.dig('step_uuid') == step.uuid
    end

    count_iteration!

    # Initialize execution_path if needed
    initialize_execution_data

    # Add step to execution path
    path_entry = build_path_entry(step)

    self.results_before_step = (results || {}).dup
    self.inputs_before_step = (inputs || {}).dup
    outcome = ScenarioStepProcessor.new(self).process(step, answer, path_entry, resolved_here: resolved_here)
    # Blocked changed nothing and must not be persisted; a sub-flow saved itself.
    return outcome unless outcome.advanced? || outcome.resolved?

    # Mark as completed if we've reached the end
    check_completion

    begin
      save!
    rescue ActiveRecord::StaleObjectError
      Rails.logger.warn "[Scenario ##{id}] Stale object on process_step — concurrent modification detected"
      return ScenarioStepProcessor::Outcome.halted(:conflict)
    end

    # Advancing to no next node ends the run just as a Resolve step does, so
    # the outcome is decided by where the run actually stands after the save.
    complete? ? ScenarioStepProcessor::Outcome.resolved : ScenarioStepProcessor::Outcome.advanced
  end

  # Process completion of a sub-flow
  def process_subflow_completion
    child = active_child_scenario || child_scenarios.where(status: 'completed').order(updated_at: :desc).first

    # If child is still running, wait
    return false if child && !child.complete?

    # Merge child results back to parent
    results_before_merge = (results || {}).dup
    if child&.results.present?
      self.results ||= {}

      # Get variable mapping from the sub-flow step
      resume_step = workflow.steps.find_by(uuid: resume_node_uuid)
      variable_mapping = resume_step&.variable_mapping || {}
      if variable_mapping.is_a?(String)
        variable_mapping = begin
          JSON.parse(variable_mapping)
        rescue JSON::ParserError
          {}
        end
      end
      variable_mapping = {} unless variable_mapping.is_a?(Hash)

      # Merge child results back to parent.
      # Explicitly mapped variables always overwrite (that's the intent of the mapping).
      # Non-mapped child results are only added if the key doesn't already exist in the
      # parent — this prevents child step titles / variable names from overwriting parent
      # values that may be used in routing conditions.
      reverse_mapping = variable_mapping.invert
      child.results.each do |key, value|
        next if key.start_with?('_') # Skip internal keys

        if reverse_mapping.key?(key)
          # Explicitly mapped: always overwrite parent value
          results[reverse_mapping[key]] = value
        else
          # Non-mapped: only add if parent doesn't already have this key
          results[key] = value unless results.key?(key)
        end
      end
    end

    stamp_subflow_merge(results_before_merge)

    # Move to next step after sub-flow
    self.status = 'active'

    resolver = StepResolver.new(workflow)
    resume_step = workflow.steps.find_by(uuid: resume_node_uuid)
    next_step = resolver.resolve_next_after_subflow(resume_step, results) if resume_step
    next_uuid = next_step.is_a?(Step) ? next_step.uuid : nil

    # Guard against self-loop: if the resolved next step is the same sub_flow step
    # we just completed, treat it as end-of-workflow rather than looping infinitely.
    if next_uuid == resume_node_uuid
      Rails.logger.warn "[Scenario ##{id}] Sub-flow step #{resume_node_uuid} resolved back to itself — breaking loop"
      advance_to_step_uuid(nil)
    else
      advance_to_step_uuid(next_uuid)
    end

    self.resume_node_uuid = nil
    check_completion

    begin
      save
    rescue ActiveRecord::StaleObjectError
      Rails.logger.warn "[Scenario ##{id}] Stale object on process_subflow_completion — concurrent modification detected"
      return false
    end

    true
  end

  # ============================================================================
  # Public methods used by ScenarioStepProcessor (formerly accessed via send())
  # ============================================================================

  def record_completion(outcome_value)
    self.outcome = outcome_value
    self.completed_at = Time.current
    if started_at.present?
      self.duration_seconds = (completed_at - started_at).to_i
    end
  end

  # Resolve the scenario at the current step (mid-step resolution via can_resolve flag)
  def resolve_at_current_step(step)
    # Mark the last execution path entry as resolved
    execution_path.last["resolved"] = true if execution_path.present?

    self.results ||= {}
    results['_resolution'] = {
      'type' => 'success',
      'resolved_at_step' => step.uuid
    }

    record_completion("resolved")
    self.status = 'completed'
    self.current_node_uuid = nil
  end

  # Advance to the next step using graph-based resolution
  def advance_to_next_step(step)
    resolver = StepResolver.new(workflow)
    next_result = resolver.resolve_next(step, results)

    if next_result.is_a?(StepResolver::SubflowMarker)
      # Will be handled in next process_step call
      advance_to_step_uuid(next_result.step_uuid)
    elsif next_result.is_a?(Step)
      advance_to_step_uuid(next_result.uuid)
    else
      advance_to_step_uuid(nil)
    end
  end

  # Append an entry to the execution path, recording what this step changed.
  #
  # The entry carries an undo log — the keys this step touched, each with the
  # value it held beforehand — not a copy of the whole variable bag.
  #
  # Back needs this. Results written by anything other than a Question cannot be
  # reconstructed from the rest of the entry: an action's output_fields land in
  # results and leave only action_completed behind, escalate leaves escalated.
  # Rebuilding the bag by replaying entries, which is what ScenarioNavigator
  # used to do, therefore destroyed every non-question value.
  #
  # A full snapshot per entry would also have worked, and is what an earlier
  # draft specified — but it is O(n) per entry and so O(n^2) per run. Measured:
  # 161KB of json for a 100-step run, which tripped the execution benchmark. The
  # delta is O(1) per entry, and any point in the run is recoverable by
  # replaying deltas forward from an empty bag.
  #
  # Internal keys are excluded: _resolution / _escalation / _error are rewritten
  # wholesale by the step that owns them, so undoing them per-key means nothing.
  # Sitting somewhere it cannot rest, needing a POST to move on.
  #
  # Two shapes: on a sub_flow node, which has no UI of its own; or awaiting a
  # child that has already finished, where the parent still needs to fold the
  # child's results in and advance. Both used to be healed inside GET step,
  # which made a read mutate state. The runner shows a Resume control instead,
  # so a run that got stuck is visible rather than silently repaired.
  #
  # Normal runs never park: ScenarioSettler leaves every POST on a step someone
  # can answer.
  def parked?
    return true if awaiting_subflow? && active_child_scenario.nil?
    return false if terminal?

    step = current_step
    step.present? && ScenarioSettler.auto_processable?(self, step)
  end

  # Whether this run can step backwards. See ScenarioNavigator#can_go_back?.
  def can_go_back?
    ScenarioNavigator.new(self).can_go_back?
  end

  def append_path_entry(entry)
    entry["results_delta"] = delta_between(results_before_step, results)
    entry["inputs_delta"] = delta_between(inputs_before_step, inputs, except: TRANSIENT_INPUT_KEYS)
    execution_path << entry
  end

  private

  # Fold what a completed sub-flow merged in onto the sub_flow entry's undo log.
  #
  # The merge happens here, long after that entry was appended, so without this
  # the child's contribution belongs to no entry and Back cannot reverse it —
  # backing past a finished sub-flow left the child's values in the parent's bag.
  #
  # Merged onto the existing delta rather than replacing it, and existing keys
  # win: the entry may already record what the sub_flow step itself changed, and
  # that prior value is the older, more correct one to restore.
  def stamp_subflow_merge(results_before_merge)
    entry = execution_path.rfind do |candidate|
      candidate["subflow_started"] && candidate["step_uuid"] == resume_node_uuid
    end
    return unless entry

    merged = delta_between(results_before_merge, results)
    entry["results_delta"] = merged.merge(entry["results_delta"] || {})
  end

  # What changed between two bags, as {key => {"was" => prior_value}}.
  #
  # A key the step added records "was" => nil, which the navigator reads as
  # "delete on undo". That is unambiguous here because no processor writes nil
  # into results or inputs — every write is guarded by .present? or is an
  # interpolated string.
  def delta_between(before, after, except: [])
    before ||= {}
    after  ||= {}

    (after.keys | before.keys).each_with_object({}) do |key, delta|
      next if key.to_s.start_with?("_")
      next if except.include?(key.to_s)
      next if before[key] == after[key]

      prior = before[key]
      delta[key] = { "was" => prior.is_a?(String) ? prior.truncate(ENTRY_TEXT_LIMIT) : prior }
    end
  end

  # Resuming a parent after its sub-flow. process_subflow_completion still
  # answers with a boolean — nothing consults more than that — so translate it
  # here rather than leaving process_step with two return types.
  def subflow_completion_outcome
    return ScenarioStepProcessor::Outcome.halted(:not_runnable) unless process_subflow_completion

    complete? ? ScenarioStepProcessor::Outcome.resolved : ScenarioStepProcessor::Outcome.advanced
  end

  def count_iteration!
    # Track iterations to prevent infinite loops in step-by-step mode
    self.iteration_count ||= execution_path&.length || 0
    self.iteration_count += 1
    return if iteration_count <= MAX_ITERATIONS

    self.status = 'error'
    self.results ||= {}
    results['_error'] = "Scenario exceeded maximum iterations (#{MAX_ITERATIONS})"
    save
    raise ScenarioIterationLimit, "Scenario exceeded maximum of #{MAX_ITERATIONS} steps"
  end

  def set_started_at
    self.started_at ||= Time.current
  end

  # Build execution path entry for a step
  def build_path_entry(step)
    entry = {
      "step_title" => step.title,
      "step_type" => step.step_type,
      "step_uuid" => step.uuid,
      "started_at" => step_started_at_pending || Time.current.iso8601(3)
    }
    self.step_started_at_pending = nil
    entry
  end

  # Advance to a specific step UUID (graph mode)
  def advance_to_step_uuid(uuid)
    self.current_node_uuid = uuid
  end

  # Check if scenario is complete
  def check_completion
    return if %w[stopped awaiting_subflow].include?(status)

    if current_node_uuid.nil?
      record_completion("completed") if outcome.blank?
      self.status = 'completed'
    else
      step = current_step
      if step.nil?
        record_completion("completed") if outcome.blank?
        self.status = 'completed'
      elsif StepResolver.new(workflow).terminal?(step) && step.step_type != 'sub_flow'
        # Terminal node that's not a sub-flow - will complete after processing
      end
    end
  end

  def evaluate_condition_string(condition_string, results)
    ConditionEvaluator.evaluate(condition_string, results)
  end

  def evaluate_condition(step, results)
    condition = step.respond_to?(:condition) ? step.condition : nil
    return false if condition.blank?

    evaluate_condition_string(condition, results)
  end
end
