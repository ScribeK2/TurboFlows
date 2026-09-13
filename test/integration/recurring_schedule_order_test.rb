require "test_helper"

# The nightly jobs have an order dependency that lives in a YAML file, where
# nothing type-checks it and a tidy-up can silently undo the reasoning.
#
# The sweep is what gives an abandoned run a `completed_at`; cleanup can only
# collect runs that have one. Both at "0 3 * * *" leaves the order undefined, and
# a run settled after the night's cleanup waits a whole extra day to be removed —
# which is invisible, because the rows do eventually go.
class RecurringScheduleOrderTest < ActiveSupport::TestCase
  SCHEDULE = Rails.application.config_for(:recurring, env: "production").freeze

  # "30 2 * * *" -> 150 minutes past midnight. Minutes, not hours, because the
  # rollup sits between two jobs an hour apart. Only the plain daily form is
  # used here; anything else is a deliberate change and should fail loudly
  # rather than be guessed at.
  def daily_minutes(cron)
    minute, hour, rest = cron.split(" ", 3)
    assert_equal "* * *", rest, "expected a plain daily schedule, got #{cron.inspect}"
    (Integer(hour) * 60) + Integer(minute)
  end

  test "all three nightly scenario jobs are still scheduled" do
    assert SCHEDULE.key?(:sweep_idle_scenarios), "the sweep is what closes the retention leak"
    assert SCHEDULE.key?(:roll_up_scenarios),    "the rollup is what makes the history outlive it"
    assert SCHEDULE.key?(:cleanup_scenarios)
    assert_equal "SweepIdleScenariosJob", SCHEDULE[:sweep_idle_scenarios][:class]
    assert_equal "RollUpScenariosJob",    SCHEDULE[:roll_up_scenarios][:class]
    assert_equal "CleanupScenariosJob",   SCHEDULE[:cleanup_scenarios][:class]
  end

  # Nothing else removes an upload that was never saved into a rich text, so if
  # this entry goes, those files quietly accumulate in storage.
  test "unattached uploads are swept nightly" do
    assert SCHEDULE.key?(:purge_unattached_blobs), "nothing else removes an upload that was never saved"
    assert_equal "PurgeUnattachedBlobsJob", SCHEDULE[:purge_unattached_blobs][:class]
    daily_minutes(SCHEDULE[:purge_unattached_blobs][:schedule])
  end

  # The three-way order, and the first night is when it matters most: the sweep
  # settles a whole backlog of abandoned runs stamped with their real last
  # activity, the rollup captures that abandonment history, and cleanup then
  # deletes the ones already past the horizon. Run cleanup before the rollup and
  # that history is gone — once, silently, and unrecoverably.
  test "sweep, then rollup, then cleanup" do
    sweep   = daily_minutes(SCHEDULE[:sweep_idle_scenarios][:schedule])
    rollup  = daily_minutes(SCHEDULE[:roll_up_scenarios][:schedule])
    cleanup = daily_minutes(SCHEDULE[:cleanup_scenarios][:schedule])

    assert_operator sweep, :<, rollup,
                    "a run the sweep has not settled yet is rolled up as pending, not as abandoned"
    assert_operator rollup, :<, cleanup,
                    "cleanup deletes the runs the rollup is summarising — roll up first, or the " \
                    "history is lost rather than aggregated"
  end
end
