# One day of runs, and of calls, for one workflow, at one purpose and outcome.
#
# Written by ScenarioRollupBuilder before the runs it describes are deleted, so
# trend history survives the retention horizon. Read by AnalyticsController
# in its all-time mode.
#
# Runs are counted on the workflow each ran in. Calls (ISSUE-003) are counted on
# the workflow each started in, with the outcome it ended with — so a row can
# carry runs, calls, or both. Days rolled before calls were counted carry none.
#
# Durations are kept as a sum and a count, never an average: averaging daily
# averages weights a day with three runs the same as a day with three hundred.
class ScenarioRollup < ApplicationRecord
  # A run that had not settled when its day was rolled up. Runs are settled
  # within a day or two (SweepIdleScenariosJob), and a day is re-rolled while it
  # is inside the refresh window, so this is normally transient — but a day that
  # closes with one is frozen that way, and the analytics total counts it, the
  # same as the live view counts an active run.
  PENDING = "pending".freeze

  belongs_to :workflow

  validates :day, :purpose, :outcome, presence: true
  validates :runs_count, :duration_sum_seconds, :duration_count,
            :calls_count, :call_duration_sum_seconds, :call_duration_count,
            numericality: { greater_than_or_equal_to: 0 }

  scope :for_days, ->(days) { where(day: days) }

  def self.average_duration_seconds
    totals = pick(Arel.sql("SUM(duration_sum_seconds)"), Arel.sql("SUM(duration_count)"))
    sum, count = totals
    return 0 if count.nil? || count.zero?

    (sum.to_f / count).round
  end

  def self.average_call_duration_seconds
    sum, count = pick(Arel.sql("SUM(call_duration_sum_seconds)"), Arel.sql("SUM(call_duration_count)"))
    return 0 if count.nil? || count.zero?

    (sum.to_f / count).round
  end
end
