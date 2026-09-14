# What an agent experiences as one run, counted as one.
#
# A call starts in one workflow and can pass through several before it ends: a
# returning sub-flow is a child scenario, and a handoff moves the run to a new
# scenario with no parent at all. Counting scenario rows counted every workflow a
# call passed through — two calls read as "Total Runs 10" — and averaged their
# durations piece by piece.
#
# A call is an origin, a scenario with neither link, taken from whatever scope
# the caller passes: a date range or a workflow filter means where the call
# started. How it ended is Scenario#run_ending, chosen here from two lookups — of
# the call's top-level frames that did not hand it on, the newest one still going,
# else the newest — and CallStatisticsTest holds the two to the same answer,
# shape by shape. Durations are worked out in Ruby from two timestamps, because
# timestamp arithmetic is spelled differently in SQLite and PostgreSQL.
class CallStatistics
  Call = Data.define(:origin_id, :ending_id, :workflow_id, :purpose, :started_at, :outcome, :completed_at) do
    def finished?
      !outcome.nil?
    end

    def duration_seconds
      return nil unless started_at && completed_at

      (completed_at - started_at).to_i
    end
  end

  def initialize(scope)
    @scope = scope
  end

  def calls
    @calls ||= load_calls
  end

  def total
    calls.size
  end

  def finished
    calls.count(&:finished?)
  end

  def completed
    calls.count { |call| Scenario::COMPLETED_OUTCOMES.include?(call.outcome) }
  end

  def escalated
    calls.count { |call| call.outcome == "escalated" }
  end

  # Keyed by outcome, with nil for a call still going: the shape the outcome
  # breakdown has always had.
  def outcome_breakdown
    calls.group_by(&:outcome).transform_values(&:size)
  end

  def average_duration_seconds
    durations = calls.filter_map(&:duration_seconds)
    durations.empty? ? 0 : (durations.sum.to_f / durations.size).round
  end

  # By the UTC day each call started, or the Monday of that week.
  def over_time(weekly:)
    started = calls.select(&:started_at)
    grouped = started.group_by do |call|
      day = call.started_at.utc.to_date
      weekly ? day.beginning_of_week : day
    end
    grouped.transform_values(&:size)
  end

  private

  def load_calls
    origins = @scope.origins
    rows = origins.pluck(:id, :workflow_id, :purpose, :started_at, :outcome, :completed_at, still_going_id)
    return [] if rows.empty?

    ending_ids = ending_ids_for(origins, rows)
    endings = Scenario.where(id: ending_ids.values)
                      .pluck(:id, :outcome, :completed_at)
                      .to_h { |id, outcome, completed_at| [id, [outcome, completed_at]] }

    rows.map do |row|
      id, workflow_id, purpose, started_at, origin_outcome, origin_completed_at, _still_going = row
      ending_id = ending_ids.fetch(id, id)
      outcome, completed_at = endings.fetch(ending_id, [origin_outcome, origin_completed_at])
      Call.new(origin_id: id, ending_id: ending_id, workflow_id: workflow_id, purpose: purpose,
               started_at: started_at, outcome: outcome, completed_at: completed_at)
    end
  end

  # origin id => ending id. A call's candidates are its top-level frames that did
  # not hand it on: the origin itself, plus every frame carrying its run_origin_id
  # (record_run_origin sets that only from a parent or handoff link, so an origin's
  # is always NULL). An origin with no candidate — a transferred frame whose
  # handed-to run is gone — is left out and falls back to itself, as
  # Scenario#run_ending does.
  #
  # Two lookups merged here, not one query filtering on
  # `id IN (origins) OR run_origin_id IN (origins)`: PostgreSQL can't hash an OR of
  # two subqueries once the origin list outgrows work_mem, so it rescanned the list
  # for every row. With 500k runs that took Analytics past its timeout and a
  # backlog roll-up past 45 minutes. The origin half is already in `rows`.
  def ending_ids_for(origins, rows)
    candidates = Hash.new { |hash, origin_id| hash[origin_id] = [nil, nil] }

    rows.each do |id, *, outcome, _completed_at, still_going|
      consider(candidates[id], still_going, id) unless outcome == "transferred"
    end

    Scenario.where(parent_scenario_id: nil, run_origin_id: origins.select(:id))
            .where(table[:outcome].eq(nil).or(table[:outcome].not_eq("transferred")))
            .group(:run_origin_id)
            .pluck(:run_origin_id, Arel::Nodes::Max.new([still_going_id]), table[:id].maximum)
            .each { |origin_id, still_going, newest| consider(candidates[origin_id], still_going, newest) }

    candidates.transform_values { |still_going, newest| still_going || newest }
  end

  # Keeps the newest still-going frame and the newest frame seen so far.
  def consider(candidate, still_going, newest)
    candidate[0] = [candidate[0], still_going].compact.max
    candidate[1] = [candidate[1], newest].compact.max
  end

  # The frame's id while it is still going, NULL once it has ended.
  def still_going_id
    Arel::Nodes::Case.new.when(table[:status].not_in(Scenario::TERMINAL_STATUSES)).then(table[:id])
  end

  def table
    Scenario.arel_table
  end
end
