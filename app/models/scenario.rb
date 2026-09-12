class Scenario < ApplicationRecord
  include ScenarioExecution

  belongs_to :workflow
  # Optional because a share link can be opened by someone who is not signed in.
  # NULL means "nobody we can name ran this", which is the truth; it used to be
  # the workflow owner, which was a lie with a consumer (per-agent analytics).
  belongs_to :user, optional: true
  # Which published version this run started against. Optional: a simulation of an
  # unpublished draft has none. `on_delete: :nullify` on the FK, but nothing
  # deletes a version — releasing one keeps the row and drops only its steps.
  belongs_to :workflow_version, optional: true

  # Parent/child scenario associations for sub-flows
  belongs_to :parent_scenario, class_name: 'Scenario', optional: true
  has_many :child_scenarios, class_name: 'Scenario', foreign_key: 'parent_scenario_id', inverse_of: :parent_scenario, dependent: :destroy
  # SPIKE (Wave 2). Deliberately NOT parent/child: a parent is waiting to be
  # returned to, and the whole point of a tail call is that nobody is waiting.
  # `dependent: :nullify` because the handed-to run outlives the half that
  # started it — destroying the source must not take the live run with it.
  belongs_to :handed_off_from, class_name: 'Scenario', optional: true
  has_one :handed_off_to, class_name: 'Scenario', foreign_key: 'handed_off_from_id',
                          inverse_of: :handed_off_from, dependent: :nullify
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

  # How long a run may sit untouched before the sweep settles it. Runs are swept
  # nightly, so the real window is this plus up to a day.
  def self.idle_timeout_hours
    ENV.fetch("SCENARIO_IDLE_TIMEOUT_HOURS", 24).to_i
  end

  # Custom error class
  class ScenarioIterationLimit < StandardError; end

  # JSON columns - automatically serialized/deserialized

  # Initialize execution_path and results as empty arrays/hashes if needed
  before_save :initialize_execution_data

  # Analytics tracking
  before_create :set_started_at

  # Which script the agent was actually following.
  #
  # The column, its index and its foreign key existed for a long time and nothing
  # ever wrote them — 0 of 120 rows in a dev database — so a schema that claimed
  # to record provenance did not. A callback rather than four assignments at the
  # Scenario.create! sites (two in PlayerController, ExecutionsController, and the
  # sub-flow child in ScenarioStepProcessor), because a child scenario runs a
  # DIFFERENT workflow and has to record that workflow's version, and a rule
  # spread across four callers is a rule that drifts.
  #
  # Nil for a simulation of an unpublished draft, which is correct: there is no
  # published version to name. It does NOT hold a snapshot alive — releasing is a
  # count, and the version's number and title are kept permanently anyway.
  before_create :record_workflow_version

  # Valid purposes
  PURPOSES = %w[simulation live].freeze
  validates :purpose, inclusion: { in: PURPOSES }, allow_nil: false

  # Valid outcomes
  # "transferred" is the handoff ending. It lives on `outcome`, not `status`,
  # because the two columns answer different questions: `status` says whether the
  # frame is finished (and must stay one of the enum's members so `terminal?`,
  # `parked?` and the cleanup scopes keep working), while `outcome` says how it
  # ended. A run that handed its work to another workflow did not *complete*, and
  # reporting has to be able to tell those apart.
  OUTCOMES = %w[completed resolved escalated abandoned error transferred].freeze
  validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true

  # The endings Analytics' completion rate counts (spec Q72, Q73): resolving,
  # escalating and handing off are all endings a workflow is built to reach.
  # "transferred" stays its own outcome, so reporting can still tell a handoff
  # from a completion. Abandoned and error are finished but not completed.
  COMPLETED_OUTCOMES = %w[completed resolved escalated transferred].freeze

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

  # Settle every run that has been idle longer than SCENARIO_IDLE_TIMEOUT_HOURS.
  #
  # This is what stops scenarios accumulating forever. Both cleanup scopes need
  # `terminal` AND a `completed_at`, and nothing ever moved an abandoned run out
  # of `active`/`awaiting_subflow` — so runs nobody finished were immortal, which
  # is the common case on a live call: agents close the tab, they do not click
  # Cancel. Settling them puts them into the existing retention pools AND makes
  # abandonment visible to `Admin::AnalyticsController#build_dropoff_points`,
  # which until now only ever heard about the few who clicked Cancel.
  #
  # `dry_run:` reports the count without writing. Use it after deploying, before
  # the first nightly pass: the backlog is settled with `completed_at` set to
  # each run's real last activity, so anything already past its retention horizon
  # becomes collectable immediately and the next CleanupScenariosJob deletes it.
  # That is the leak draining, but it should not be a surprise.
  def self.sweep_idle_runs(dry_run: false)
    cutoff = idle_timeout_hours.hours.ago
    seen   = Set.new
    swept  = 0

    # By id, then re-read: the backlog pass can be long and an agent may resume a
    # run while it is in flight. Re-reading gives the lock_version check something
    # current to fail against, which is the point of the rescue below.
    where(status: %w[active awaiting_subflow]).order(:id).pluck(:id).each do |id|
      next if seen.include?(id)

      frame = find_by(id: id)
      next if frame.nil?

      frames = frame.run_frames
      # Mark the whole run seen even if it is not idle, so a run with five frames
      # is walked once rather than five times.
      seen.merge(frames.map(&:id))

      last_activity = frames.filter_map(&:updated_at).max
      next if last_activity.nil? || last_activity >= cutoff
      next swept += 1 if dry_run

      begin
        transaction do
          frames.reject(&:terminal?).each { |f| f.time_out_frame!(last_activity) }
        end
        swept += 1
      rescue ActiveRecord::StaleObjectError
        # Someone is on this run after all. Leave it; the next pass will decide
        # again with a fresh clock. One contended run must not abort the batch.
        Rails.logger.warn("[sweep_idle_runs] Scenario ##{id} changed mid-sweep — left for the next pass")
      end
    end

    swept
  end

  # Non-terminal rows, for the data-health dashboard. If this climbs without
  # bound after the sweep ships, the sweep is not reaching something.
  def self.outstanding_non_terminal
    where(status: %w[active awaiting_subflow]).count
  end

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
    # Cheap guard first, and no separate existence check: find_by already
    # answers nil for a workflow with no steps, so `steps.any?` was a query
    # asked before every lookup to learn nothing. This runs on every advance and
    # again on every render.
    return nil if current_node_uuid.blank?

    workflow&.steps&.find_by(uuid: current_node_uuid)
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

  # Where the run started, and where it lives now.
  #
  # These exist because four separate readers each worked out "where does this
  # run live" from `parent_scenario_id` or `root_scenario`, and three review
  # rounds plus one spike each found a different one wrong — twice at the same
  # line. `root_scenario` answers a narrower question (the top of *one* parent
  # chain) and is kept for callers that genuinely mean that; anything asking
  # about the run as a whole wants one of these two.
  #
  # A handoff is not a parent link, so a chain can alternate:
  #   A --sub-flow--> B --handoff--> C --sub-flow--> D
  # Neither link alone spans that, which is why both walks alternate rather than
  # following one FK.

  # Backward, to the workflow the agent actually started in.
  def run_origin
    frame = self
    seen = Set.new
    loop do
      frame = frame.root_scenario
      # Guard the walk rather than trusting the data: a handoff cycle is refused
      # at publish, but a primitive several readers depend on must not hang if
      # one ever gets through.
      break frame unless frame.handed_off_from && seen.add?(frame.id)

      frame = frame.handed_off_from
    end
  end

  # Forward, to the frame the run currently lives on.
  #
  # Alternates both links, for the mirror of the reason run_origin does. One hop
  # is not enough — for A -> B -> C with B already handed on, `A.handed_off_to`
  # is B and B is terminal — and neither is following `handed_off_to` alone:
  # in `A --sub-flow--> B --handoff--> C` it is B that hands the run away, and
  # settling the handoff terminates A as well. So `A.handed_off_to` is nil while
  # the run is very much alive in C, and a caller that stopped at A rendered a
  # finished run over the agent's live work.
  #
  # A stopped branch is not where the run is, so the descent skips it: the
  # handed-to row can be abandoned (a rewind, a lost lock race) while a live one
  # exists alongside it.
  def run_head
    frame = self
    seen = Set.new([id])

    loop do
      nxt = frame.live_handed_off_to || handed_off_descendant_of(frame)
      break frame unless nxt && seen.add?(nxt.id)

      frame = nxt
    end
  end

  # The handed-to run of this frame, ignoring branches that were abandoned.
  def live_handed_off_to
    branches = Scenario.where(handed_off_from_id: id).where.not(status: "stopped").order(:id)
    # A frame the run is still on beats a finished one. Ordering by id alone
    # picked the newest even when it was terminal and an older sibling was still
    # active, which stranded the agent on a dead page.
    branches.reject(&:terminal?).last || branches.last
  end

  private

  # A handoff issued from *inside* this frame: the run left through a sub-flow
  # of ours, so the forward link hangs off that child rather than off us.
  def handed_off_descendant_of(frame)
    # `each`, not `find_each`: find_each discards any order and logs a WARN
    # about it on every call — and this runs on every runner GET, so it put a
    # warning in the production log for a feature most runs never touch. At most
    # a couple of rows, so batching buys nothing and the order becomes real.
    frame.child_scenarios.where(outcome: "transferred").order(:id).each do |child|
      found = child.live_handed_off_to || handed_off_descendant_of(child)
      return found if found
    end
    nil
  end

  public

  # Check if scenario is complete
  def complete?
    # Terminal is terminal. This enumerated two of the four end states and then
    # fell through to `current_node_uuid.nil? && !active?`, so a run that died on
    # the iteration limit was "not complete" and the runner handed the agent an
    # answerable card on it. Nulling current_node_uuid also hides that, but only
    # while two columns happen to line up — say it once, here.
    return true if terminal?
    return true if completed?
    return true if stopped?
    return false if awaiting_subflow?
    return true unless workflow&.steps&.any?

    # Complete when no current node
    current_node_uuid.nil? && !active?
  end

  # The frame the run ended on, or is on now — where to read how it ended.
  #
  # Of every frame in the run, the top-level ones that did not hand it on. One
  # still going beats a finished one; between finished ones the newest by id
  # wins, which is MAX(id), so the SQL that counts calls can say the same thing.
  #
  # Not `run_head`, which skips stopped branches because a stopped handed-to row
  # beside a live one is not where the run lives. When an agent cancels after a
  # handoff, the stopped frame is the only thing after it: `run_head` from the
  # origin stopped on the transferred frame before, and a results page reading
  # that said "Completed" for a run the agent had stopped.
  def run_ending
    endings = run_frames.select { |frame| frame.parent_scenario_id.nil? && frame.outcome != "transferred" }
    endings.reject(&:terminal?).max_by(&:id) || endings.max_by(&:id) || run_origin
  end

  # How long the whole run took, from where it started to where it ended — not
  # this frame's own `duration_seconds`, which stops at a handoff. Nil while the
  # run is still going.
  def run_duration_seconds
    finished = run_ending.completed_at
    started = run_origin.started_at
    return nil unless finished && started

    (finished - started).to_i
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

  # End this frame, and every frame waiting on it, because the run has been
  # handed to another workflow and will never come back here.
  #
  # A handoff is not "this frame ends". `A -> sub-flow B -> handoff C` leaves A
  # waiting for a return that will never come: `parked?` becomes true (its child
  # is no longer active), and the Resume it offers calls
  # `process_subflow_completion`, which picks the newest completed child and
  # RESURRECTS A. Review found that shape twice at scenario.rb:314 and the
  # handoff spike found it a third time, so the rule is enforced here rather than
  # left to each caller.
  #
  # Only frames genuinely *waiting* are settled — `stop_frame!` already refuses
  # to touch a terminal scenario, and an ancestor that ended on its own keeps the
  # outcome it earned.
  def hand_off!
    transaction do
      settle_as_transferred!
      frame = parent_scenario
      while frame
        frame.settle_as_transferred!
        frame = frame.parent_scenario
      end
    end
  end

  # One frame's half of that. Public so hand_off! can walk the chain; not a
  # public API otherwise.
  def settle_as_transferred!
    return if terminal?

    self.status = 'completed'
    self.current_node_uuid = nil
    record_completion('transferred')
    save!
  end

  # True once the run reached an end state and its outcome is settled.
  def terminal?
    # `status` is the enum READER, which returns the LABEL ("timed_out"), while
    # TERMINAL_STATUSES holds the DB VALUES ("timeout") that the `terminal` scope
    # needs for its `where`. For completed/stopped label and value are identical,
    # which is why this read correctly for years; for the two members where they
    # differ — timed_out => "timeout", errored => "error" — it returned false,
    # and Ruby disagreed with SQL about the same row.
    #
    # That was live, not latent: `status = 'error'` is written by count_iteration!
    # and by ScenarioStepProcessor#process_subflow_step. An errored run had its
    # outcome overwritten by stop_frame!, was picked as the live head by
    # live_handed_off_to, and rendered an answerable card in the runner.
    #
    # Translate rather than keeping a second list in the other representation.
    TERMINAL_STATUSES.include?(self.class.statuses[status])
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

  # Every frame of the run this frame belongs to.
  #
  # The SIXTH reader of run topology, and the previous five were each wrong in a
  # different way (see docs/designs/idle-sweep-spike-findings.md). It exists
  # because no earlier one answers "the whole run":
  #
  #   - `root_scenario` / `unfinished_descendants` walk `parent_scenario` only,
  #     and a handed-to run has no parent by design, so they stop at a handoff.
  #   - `run_origin` and `run_head` cross handoffs but do NOT descend into an
  #     ordinary sub-flow child, so neither enumerates a parked parent's children.
  #
  # So this seeds from `run_origin` and closes over BOTH links in BOTH directions.
  # Order is not meaningful; membership is.
  def run_frames
    seen  = {}
    queue = [run_origin]

    until queue.empty?
      frame = queue.shift
      next if frame.nil? || seen.key?(frame.id)

      seen[frame.id] = frame
      queue.concat(frame.child_scenarios.to_a)
      queue.concat(Scenario.where(handed_off_from_id: frame.id).to_a)
      queue << frame.parent_scenario
      queue << frame.handed_off_from
    end

    seen.values
  end

  # When the run — not this frame — was last touched.
  #
  # It has to be the whole run. `belongs_to :parent_scenario` has no `touch:`, so
  # a parent parked on a LIVE sub-flow has a clock that stopped when it parked,
  # and `run_head` returns that parent as the head. Keying anything on a single
  # frame settles runs an agent is still working. Spike probe P2b.
  def run_last_activity
    run_frames.filter_map(&:updated_at).max
  end

  def run_idle?(threshold = self.class.idle_timeout_hours.hours)
    last = run_last_activity
    last.present? && last < threshold.ago
  end

  # Settle this run as abandoned because nobody came back to it.
  #
  # Named `time_out!` rather than `timed_out!` because the enum already defines
  # the latter: it flips the status and records nothing, which is exactly the
  # shape of the bug that left errored runs with a NULL completed_at and made
  # them uncollectable.
  #
  # `status` says the run is over; `outcome` says how. "abandoned" is shared with
  # an explicit Cancel deliberately — drop-off analysis asks "did the agent
  # finish", not which gesture ended it — and `status` still separates the two
  # ("stopped" vs "timeout") for anyone who needs to know.
  def time_out!
    at = run_last_activity
    transaction do
      run_frames.reject(&:terminal?).each { |frame| frame.time_out_frame!(at) }
    end
  end

  # One frame's half of that. Public so time_out! can walk the run; not a public
  # API otherwise. Mirrors stop_frame!, including its refusal to touch a frame
  # that already ended with an outcome it earned.
  def time_out_frame!(at)
    return if terminal?

    record_completion("abandoned", at: at)
    # Nulling the node is not decoration: `complete?` is what the runner asks
    # before offering an answerable card, and a settled run must never leave one.
    update!(status: "timeout", current_node_uuid: nil)
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

  # `at:` because a swept run did not end when the sweep noticed. Its ending is
  # the run's last real activity, and duration has to be measured to that same
  # point — stamping completed_at afterwards would leave duration_seconds
  # measured to the wrong end. See Scenario.sweep_idle_runs.
  def record_completion(outcome_value, at: Time.current)
    self.outcome = outcome_value
    self.completed_at = at
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
    # An ending is not just a status. Without this the run was terminal with a
    # NULL completed_at, and both cleanup scopes filter on `completed_at < N.ago`
    # — NULL < date is never true — so every errored run was immortal.
    record_completion("error")
    save
    raise ScenarioIterationLimit, "Scenario exceeded maximum of #{MAX_ITERATIONS} steps"
  end

  def record_workflow_version
    self.workflow_version_id ||= workflow&.published_version_id
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
