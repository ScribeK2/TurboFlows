require "test_helper"

# Regression: ISSUE-001 — results after a handoff showed only the last workflow
# Found by /qa on 2026-09-12
# Report: .gstack/qa-reports/qa-report-localhost-2026-09-12.md
#
# `run_ending` is the frame a run ended on, or is still on. The results pages need
# it for how the run ended — status, resolution, when it finished — while the
# path and the title come from `run_origin`.
#
# It is not `run_head`. `run_head` skips stopped branches, because a stopped
# handed-to row next to a live one is not where the run lives. But when an agent
# cancels after a handoff, the stopped frame is the ONLY thing after the handoff:
# `run_head` from the origin stops on the transferred frame before it, and a
# results page reading that frame said "Completed" for a run the agent stopped.
# Found against a real cancelled chain in the dev database, where the head was
# S687 (transferred) and the ending S688 (stopped).
#
# Every shape is asserted from every frame, because the previous readers of run
# topology were each right from the frame their author was looking at.
class ScenarioRunEndingTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "ending-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    @wf = Workflow.create!(title: "W #{SecureRandom.hex(3)}", user: @user)
    @t0 = Time.zone.parse("2026-09-01 09:00:00")
  end

  def frame(parent: nil, handed_off_from: nil, status: "active", outcome: nil, started: 0, finished: nil)
    Scenario.create!(workflow: @wf, user: @user, purpose: "live", status: status, outcome: outcome,
                     parent_scenario: parent, handed_off_from: handed_off_from,
                     started_at: @t0 + started.seconds,
                     completed_at: finished && (@t0 + finished.seconds),
                     execution_path: [], results: {}, inputs: {})
  end

  def assert_ending(expected, frames)
    frames.each do |f|
      assert_equal expected, f.reload.run_ending, "from S#{f.id}"
    end
  end

  test "a run that never left one workflow ends on itself" do
    a = frame(status: "completed", outcome: "resolved", finished: 90)

    assert_ending a, [a]
    assert_equal 90, a.run_duration_seconds
  end

  test "a run inside an ordinary sub-flow ends on the parent, not the child" do
    a = frame(status: "completed", outcome: "resolved", finished: 120)
    b = frame(parent: a, status: "completed", outcome: "resolved", started: 10, finished: 60)

    assert_ending a, [a, b]
    assert_equal 120, b.run_duration_seconds
  end

  test "after a handoff the run ends on the workflow it was handed to" do
    a = frame(status: "completed", outcome: "transferred", finished: 40)
    b = frame(handed_off_from: a, status: "completed", outcome: "resolved", started: 40, finished: 100)

    assert_ending b, [a, b]
    assert_equal 100, a.run_duration_seconds,
                 "the whole call, not the 40 seconds before the handoff"
  end

  # The shape run_head gets wrong.
  test "a run cancelled after two handoffs ends on the stopped frame" do
    a = frame(status: "completed", outcome: "transferred", finished: 30)
    b = frame(handed_off_from: a, status: "completed", outcome: "transferred", started: 30, finished: 60)
    c = frame(handed_off_from: b, status: "stopped", outcome: "abandoned", started: 60, finished: 150)

    assert_ending c, [a, b, c]
    assert_equal b, a.run_head, "run_head skips the stopped branch, which is why run_ending exists"
    assert_equal 150, b.run_duration_seconds
  end

  test "a handoff made from inside a sub-flow ends on the handed-to workflow" do
    a = frame(status: "completed", outcome: "transferred", finished: 50)
    b = frame(parent: a, status: "completed", outcome: "transferred", started: 5, finished: 50)
    c = frame(handed_off_from: b, status: "completed", outcome: "escalated", started: 50, finished: 80)
    d = frame(parent: c, status: "completed", outcome: "resolved", started: 55, finished: 70)

    assert_ending c, [a, b, c, d]
  end

  test "a run still going ends, for now, on the frame it is on, and has no duration yet" do
    a = frame(status: "completed", outcome: "transferred", finished: 20)
    b = frame(handed_off_from: a, started: 20)

    assert_ending b, [a, b]
    assert_nil a.run_duration_seconds
  end

  # A handed-to row abandoned alongside a live one (a lost lock race) is the case
  # run_head's stopped-branch rule exists for. Here the live one must win too.
  test "a live frame beats an abandoned sibling" do
    a = frame(status: "completed", outcome: "transferred", finished: 20)
    stale = frame(handed_off_from: a, status: "stopped", outcome: "abandoned", started: 20, finished: 21)
    live = frame(handed_off_from: a, started: 21)

    assert_operator stale.id, :<, live.id
    assert_ending live, [a, stale, live]
  end

  test "between finished frames, the newest by id is the ending" do
    a = frame(status: "completed", outcome: "transferred", finished: 20)
    older = frame(handed_off_from: a, status: "stopped", outcome: "abandoned", started: 20, finished: 21)
    newer = frame(handed_off_from: a, status: "completed", outcome: "resolved", started: 21, finished: 90)

    assert_ending newer, [a, older, newer]
  end
end
