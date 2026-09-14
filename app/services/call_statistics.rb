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
# shape by shape.
#
# The calls can be read two ways. `calls` lists them one by one, for pages that
# show a handful: one agent's calls, a CSR's recent runs, a night's roll-up. The
# headline figures add them up in one query instead, grouped by how each call
# ended and the day it started, because loading every call just to count it
# took a 90-day Analytics page on the load-test replica (496k calls) 6 seconds
# and 430 MiB a request. That query subtracts timestamps, which SQLite and
# PostgreSQL spell differently, so it is written for each, and
# CallStatisticsTest holds both ways of reading to the same figures.
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

  # The calls that ended with one outcome and started on one UTC day.
  Tally = Data.define(:outcome, :day, :calls, :duration_sum, :duration_count)

  def initialize(scope)
    @scope = scope
  end

  def calls
    @calls ||= load_calls
  end

  def total
    tallies.sum(&:calls)
  end

  def finished
    tallies.reject { |tally| tally.outcome.nil? }.sum(&:calls)
  end

  def completed
    tallies.select { |tally| Scenario::COMPLETED_OUTCOMES.include?(tally.outcome) }.sum(&:calls)
  end

  def escalated
    tallies.select { |tally| tally.outcome == "escalated" }.sum(&:calls)
  end

  # Keyed by outcome, with nil for a call still going: the shape the outcome
  # breakdown has always had. Commonest first: the query's groups come back in no
  # fixed order, and the Overview lists them as they come.
  def outcome_breakdown
    counts = tallies.group_by(&:outcome).transform_values { |group| group.sum(&:calls) }
    counts.sort_by { |outcome, count| [-count, outcome.to_s] }.to_h
  end

  def average_duration_seconds
    count = tallies.sum(&:duration_count)
    count.zero? ? 0 : (tallies.sum(&:duration_sum).to_f / count).round
  end

  # By the UTC day each call started, or the Monday of that week.
  def over_time(weekly:)
    started = tallies.select(&:day)
    grouped = started.group_by { |tally| weekly ? tally.day.beginning_of_week : tally.day }
    grouped.transform_values { |group| group.sum(&:calls) }
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

    handed_to_frames(origins)
      .pluck(:run_origin_id, Arel::Nodes::Max.new([still_going_id]), table[:id].maximum)
      .each { |origin_id, still_going, newest| consider(candidates[origin_id], still_going, newest) }

    candidates.transform_values { |still_going, newest| still_going || newest }
  end

  # Keeps the newest still-going frame and the newest frame seen so far.
  def consider(candidate, still_going, newest)
    candidate[0] = [candidate[0], still_going].compact.max
    candidate[1] = [candidate[1], newest].compact.max
  end

  def tallies
    @tallies ||= load_tallies
  end

  # Each origin, joined to its handed-to frames (few calls have any) and then to
  # its ending, counted by the ending's outcome and the origin's day.
  def load_tallies
    origins = @scope.origins
    handed_to = handed_to_frames(origins)
                .select(table[:run_origin_id].as("origin_id"), Arel::Nodes::Max.new([still_going_id]).as("still_going_id"),
                        table[:id].maximum.as("newest_id"))

    origins.joins("LEFT JOIN (#{handed_to.to_sql}) handed_to ON handed_to.origin_id = scenarios.id")
           .joins("INNER JOIN scenarios endings ON endings.id = #{ending_id}")
           .group(Arel.sql("endings.outcome"), Arel.sql(started_day))
           .pluck(Arel.sql("endings.outcome"), Arel.sql(started_day), Arel.sql("COUNT(*)"),
                  Arel.sql("SUM(#{duration})"), Arel.sql("COUNT(#{duration})"))
           .map do |outcome, day, count, duration_sum, duration_count|
             Tally.new(outcome: outcome, day: day&.to_date, calls: count, duration_sum: duration_sum.to_i,
                       duration_count: duration_count)
           end
  end

  # Every frame past the origin that could be where a call ended, one group per
  # call. A single `run_origin_id IN (SELECT ...)` is a hash semi-join, which
  # PostgreSQL batches however many origins there are.
  def handed_to_frames(origins)
    Scenario.where(parent_scenario_id: nil, run_origin_id: origins.select(:id))
            .where(not_handed_on)
            .group(:run_origin_id)
  end

  # Scenario#run_ending's order: the newest handed-to frame still going, else the
  # origin if it is, else the newest handed-to frame, else the origin. A frame is
  # created after the origin it records, so a handed-to frame's id is always the
  # larger one and the two never need comparing.
  def ending_id
    origin_still_going = Arel::Nodes::Case.new.when(going.and(not_handed_on)).then(table[:id])
    "COALESCE(handed_to.still_going_id, #{origin_still_going.to_sql}, handed_to.newest_id, scenarios.id)"
  end

  # Whole seconds from the origin's start to the ending's finish, cut as
  # Call#duration_seconds cuts them. SQLite has no interval type, so it subtracts
  # Julian days, rounded to the millisecond to shed the floating-point error.
  def duration
    if sqlite?
      "CAST(ROUND((julianday(endings.completed_at) - julianday(scenarios.started_at)) * 86400000) AS INTEGER) / 1000"
    else
      "TRUNC(EXTRACT(EPOCH FROM (endings.completed_at - scenarios.started_at)))"
    end
  end

  # Timestamps are stored in UTC, so this is the UTC day.
  def started_day
    sqlite? ? "date(scenarios.started_at)" : "scenarios.started_at::date"
  end

  def sqlite?
    Scenario.connection_db_config.adapter == "sqlite3"
  end

  # The frame's id while it is still going, NULL once it has ended.
  def still_going_id
    Arel::Nodes::Case.new.when(going).then(table[:id])
  end

  def going
    table[:status].not_in(Scenario::TERMINAL_STATUSES)
  end

  def not_handed_on
    table[:outcome].eq(nil).or(table[:outcome].not_eq("transferred"))
  end

  def table
    Scenario.arel_table
  end
end
