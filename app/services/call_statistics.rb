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

  # Counted in two parts, then added together. Most calls end where they
  # started, so they are grouped by the origin's own outcome and day, which
  # PostgreSQL can estimate (statistics scenarios_started_day) and so groups in
  # memory. The few handed on are joined to their endings through `handed_to`
  # first. Joining every origin to its ending in one query hashed the whole
  # table and spilled to temp files: on the load-test replica one 90-day page in
  # four took 2.5 s instead of 0.8.
  def load_tallies
    origins = @scope.origins
    ended_where_started = origins.where("NOT EXISTS (SELECT 1 FROM handed_to WHERE handed_to.origin_id = scenarios.id)")
                                 .group(Arel.sql("scenarios.outcome"), Arel.sql(started_day))
                                 .select(*tally_columns("scenarios.outcome", "scenarios.completed_at"))
    handed_on = origins.joins("INNER JOIN handed_to ON handed_to.origin_id = scenarios.id")
                       .group(Arel.sql(ending("outcome")), Arel.sql(started_day))
                       .select(*tally_columns(ending("outcome"), ending("completed_at")))

    Scenario.unscoped
            .with(handed_to: handed_to(origins), tallies: [ended_where_started, handed_on])
            .from("tallies")
            .group(Arel.sql("tallies.outcome"), Arel.sql("tallies.day"))
            .pluck(Arel.sql("tallies.outcome"), Arel.sql("tallies.day"), Arel.sql("SUM(tallies.calls)"),
                   Arel.sql("SUM(tallies.duration_sum)"), Arel.sql("SUM(tallies.duration_count)"))
            .map do |outcome, day, calls, duration_sum, duration_count|
              # A SUM of counts arrives from PostgreSQL as a BigDecimal.
              Tally.new(outcome: outcome, day: day&.to_date, calls: calls.to_i, duration_sum: duration_sum.to_i,
                        duration_count: duration_count.to_i)
            end
  end

  def tally_columns(outcome, completed_at)
    duration = Arel.sql(duration_between(completed_at))
    [Arel.sql(outcome).as("outcome"), Arel.sql(started_day).as("day"), Arel.star.count.as("calls"),
     Arel::Nodes::Sum.new([duration]).as("duration_sum"), Arel::Nodes::Count.new([duration]).as("duration_count")]
  end

  # One row per call handed on: whether one of its frames is still going, and
  # the outcome and finish of its newest frame still going, else its newest.
  def handed_to(origins)
    frames = handed_to_frames(origins)
             .select(table[:run_origin_id].as("origin_id"), Arel::Nodes::Max.new([still_going_id]).as("still_going_id"),
                     table[:id].maximum.as("newest_id"))
    Scenario.unscoped
            .from(frames, :frames)
            .joins("INNER JOIN scenarios ON scenarios.id = COALESCE(frames.still_going_id, frames.newest_id)")
            .select("frames.origin_id", "frames.still_going_id", "scenarios.outcome", "scenarios.completed_at")
  end

  # Every frame past the origin that could be where a call ended, one group per
  # call. A single `run_origin_id IN (SELECT ...)` is a hash semi-join, which
  # PostgreSQL batches however many origins there are.
  def handed_to_frames(origins)
    Scenario.where(parent_scenario_id: nil, run_origin_id: origins.select(:id))
            .where(not_handed_on)
            .group(:run_origin_id)
  end

  # A handed-on call's ending, in Scenario#run_ending's order: its frame still
  # going, else the origin if the origin is still going, else its newest frame.
  # A frame is created after the origin it records, so its id is always the
  # larger and the two never need comparing.
  def ending(column)
    "CASE WHEN handed_to.still_going_id IS NOT NULL OR NOT (#{going.and(not_handed_on).to_sql}) " \
      "THEN handed_to.#{column} ELSE scenarios.#{column} END"
  end

  # Whole seconds from the origin's start to `completed_at`, cut as
  # Call#duration_seconds cuts them. SQLite has no interval type, so it subtracts
  # Julian days, rounded to the millisecond to shed the floating-point error.
  def duration_between(completed_at)
    if sqlite?
      "CAST(ROUND((julianday(#{completed_at}) - julianday(scenarios.started_at)) * 86400000) AS INTEGER) / 1000"
    else
      "TRUNC(EXTRACT(EPOCH FROM (#{completed_at} - scenarios.started_at)))"
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
