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
# started. How it ended is Scenario#run_ending, chosen here in SQL — of the
# call's top-level frames that did not hand it on, the newest one still going,
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
    origins = @scope.where(parent_scenario_id: nil, handed_off_from_id: nil)
    rows = origins.pluck(:id, :workflow_id, :purpose, :started_at, :outcome, :completed_at)
    return [] if rows.empty?

    ending_ids = ending_ids_for(origins)
    endings = Scenario.where(id: ending_ids.values)
                      .pluck(:id, :outcome, :completed_at)
                      .to_h { |id, outcome, completed_at| [id, [outcome, completed_at]] }

    rows.map do |row|
      id, workflow_id, purpose, started_at, origin_outcome, origin_completed_at = row
      ending_id = ending_ids.fetch(id, id)
      outcome, completed_at = endings.fetch(ending_id, [origin_outcome, origin_completed_at])
      Call.new(origin_id: id, ending_id: ending_id, workflow_id: workflow_id, purpose: purpose,
               started_at: started_at, outcome: outcome, completed_at: completed_at)
    end
  end

  # origin id => ending id. An origin with no candidate — a transferred frame
  # whose handed-to run is gone — is left out and falls back to itself, as
  # Scenario#run_ending does.
  def ending_ids_for(origins)
    table = Scenario.arel_table
    call = Arel::Nodes::NamedFunction.new("COALESCE", [table[:run_origin_id], table[:id]])
    still_going = Arel::Nodes::Case.new.when(table[:status].not_in(Scenario::TERMINAL_STATUSES)).then(table[:id])
    ending = Arel::Nodes::NamedFunction.new("COALESCE", [Arel::Nodes::Max.new([still_going]), table[:id].maximum])

    Scenario.where(parent_scenario_id: nil)
            .where(table[:outcome].eq(nil).or(table[:outcome].not_eq("transferred")))
            .where(call.in(origins.select(:id).arel))
            .group(call)
            .pluck(call, ending)
            .to_h
  end
end
