require 'timeout'

class Scenario < ApplicationRecord
  include ScenarioExecution

  belongs_to :workflow
  belongs_to :user

  # Parent/child scenario associations for sub-flows
  belongs_to :parent_scenario, class_name: 'Scenario', optional: true
  has_many :child_scenarios, class_name: 'Scenario', foreign_key: 'parent_scenario_id', dependent: :destroy
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

  # Scenario limits to prevent infinite loops and DoS
  MAX_ITERATIONS = ENV.fetch("SCENARIO_MAX_ITERATIONS", 1000).to_i
  MAX_EXECUTION_TIME = ENV.fetch("SCENARIO_MAX_SECONDS", 30).to_i # seconds
  MAX_CONDITION_DEPTH = 50 # Max nested condition evaluations per step

  # Retention periods for cleanup (days)
  def self.simulation_retention_days
    ENV.fetch("SCENARIO_RETENTION_SIMULATION_DAYS", 7).to_i
  end

  def self.live_retention_days
    ENV.fetch("SCENARIO_RETENTION_LIVE_DAYS", 90).to_i
  end

  # Custom error classes
  class ScenarioTimeout < StandardError; end
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
  scope :terminal, -> { where(status: %w[completed stopped timeout error]) }

  scope :stale_simulations, lambda {
    terminal.where(purpose: "simulation")
            .where("COALESCE(completed_at, updated_at) < ?", simulation_retention_days.days.ago)
  }

  scope :stale_live, lambda {
    terminal.where(purpose: "live")
            .where("COALESCE(completed_at, updated_at) < ?", live_retention_days.days.ago)
  }

  # Deletes stale scenarios and their children. Returns the number of stale
  # parent scenarios removed (excludes cascaded children from the count).
  # Uses delete_all for performance — bypasses callbacks and dependent: :destroy.
  # If Scenario gains destroy callbacks, revisit this approach.
  def self.cleanup_stale
    stale_ids = (stale_simulations.pluck(:id) + stale_live.pluck(:id)).uniq
    return 0 if stale_ids.empty?

    # Delete ALL children of stale parents first (including active/stuck ones —
    # if the parent is terminal and past retention, any remaining child is orphaned).
    # FK is ON DELETE NULLIFY, not CASCADE, so this must be explicit.
    where(parent_scenario_id: stale_ids).delete_all
    where(id: stale_ids).delete_all

    stale_ids.size
  end

  # Enum handles status validation automatically

  # Track iteration count for step-by-step processing
  attr_accessor :iteration_count

  # Pending timestamp set when a step is displayed, consumed when path entry is built
  attr_accessor :step_started_at_pending

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
    return nil unless current_node_uuid.present?

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

  # Stop the workflow execution
  def stop!(step_index = nil)
    record_completion("abandoned")
    update!(
      status: 'stopped',
      stopped_at_step_index: step_index || current_step_index
    )
  end

  # Process a single step and advance
  # Returns false if step can't be processed, true otherwise
  # Raises ScenarioIterationLimit if max iterations exceeded
  def process_step(answer = nil, resolved_here: false)
    return false if complete?
    return false if stopped?
    return false if timed_out? || errored?

    # If awaiting sub-flow completion, check child status
    if awaiting_subflow?
      return process_subflow_completion
    end

    step = current_step
    return false unless step

    # Idempotency guard: prevent re-processing the same non-interactive step.
    # Question and form steps are excluded because users can legitimately re-answer after back navigation.
    if execution_path.present? && %w[question form].exclude?(step.step_type)
      last_entry = execution_path.last
      return false if last_entry&.dig('step_uuid') == step.uuid
    end

    # Track iterations to prevent infinite loops in step-by-step mode
    self.iteration_count ||= execution_path&.length || 0
    self.iteration_count += 1

    if iteration_count > MAX_ITERATIONS
      self.status = 'error'
      self.results ||= {}
      self.results['_error'] = "Scenario exceeded maximum iterations (#{MAX_ITERATIONS})"
      save
      raise ScenarioIterationLimit, "Scenario exceeded maximum of #{MAX_ITERATIONS} steps"
    end

    # Initialize execution_path if needed
    initialize_execution_data

    # Add step to execution path
    path_entry = build_path_entry(step)

    processor = ScenarioStepProcessor.new(self)
    result = processor.process(step, answer, path_entry, resolved_here: resolved_here)
    return result if step.step_type == 'sub_flow'

    # Mark as completed if we've reached the end
    check_completion

    begin
      save!
    rescue ActiveRecord::StaleObjectError
      Rails.logger.warn "[Scenario ##{id}] Stale object on process_step — concurrent modification detected"
      return false
    end
  end

  # Process completion of a sub-flow
  def process_subflow_completion
    child = active_child_scenario || child_scenarios.where(status: 'completed').order(updated_at: :desc).first

    # If child is still running, wait
    return false if child && !child.complete?

    # Merge child results back to parent
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
          self.results[reverse_mapping[key]] = value
        else
          # Non-mapped: only add if parent doesn't already have this key
          self.results[key] = value unless self.results.key?(key)
        end
      end
    end

    # Move to next step after sub-flow
    self.status = 'active'

    resolver = StepResolver.new(workflow)
    resume_step = workflow.steps.find_by(uuid: resume_node_uuid)
    next_step = resolver.resolve_next_after_subflow(resume_step, self.results) if resume_step
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

  def execute
    return false unless workflow.present? && inputs.present?

    # Wrap execution with timeout protection
    Timeout.timeout(MAX_EXECUTION_TIME, ScenarioTimeout) do
      execute_with_limits
    end
  rescue ScenarioTimeout
    self.status = 'timeout'
    self.results ||= {}
    self.results['_error'] = "Scenario timed out after #{MAX_EXECUTION_TIME} seconds"
    record_completion("error")
    save
    Rails.logger.warn "Scenario #{id} timed out for workflow #{workflow_id}"
    false
  rescue ScenarioIterationLimit
    record_completion("error")
    save
    Rails.logger.warn "Scenario #{id} hit iteration limit for workflow #{workflow_id}"
    false
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
    self.execution_path.last[:resolved] = true if execution_path.present?

    self.results ||= {}
    self.results['_resolution'] = {
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
    next_result = resolver.resolve_next(step, self.results)

    if next_result.is_a?(StepResolver::SubflowMarker)
      # Will be handled in next process_step call
      advance_to_step_uuid(next_result.step_uuid)
    elsif next_result.is_a?(Step)
      advance_to_step_uuid(next_result.uuid)
    else
      advance_to_step_uuid(nil)
    end
  end

  private

  def set_started_at
    self.started_at ||= Time.current
  end

  # Build execution path entry for a step
  def build_path_entry(step)
    entry = {
      step_title: step.title,
      step_type: step.step_type,
      step_uuid: step.uuid,
      started_at: step_started_at_pending || Time.current.iso8601(3)
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
      record_completion("completed") unless outcome.present?
      self.status = 'completed'
    else
      step = current_step
      if step.nil?
        record_completion("completed") unless outcome.present?
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
    return false unless condition.present?

    evaluate_condition_string(condition, results)
  end

end
