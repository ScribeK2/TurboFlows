require "test_helper"

# The two ends of a run, as primitives rather than inferences.
#
# Four separate readers each worked
# out "where does this run live" for themselves, from `parent_scenario_id` or
# `root_scenario`, and three review rounds each found a different one wrong —
# twice at `scenario.rb:314`. The spike found a fourth from a third direction.
# These two methods are the one place that question gets answered.
#
# `run_origin` — where the run started. Walks BACKWARD, alternating both links.
# `run_head`   — where the run lives now. Walks FORWARD along handoffs.
#
# The shape that breaks a naive version of either is a MIXED chain:
#   A --sub-flow--> B --handoff--> C --sub-flow--> D
# Neither link alone spans it.
class ScenarioRunOriginTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "origin-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    @wf = Workflow.create!(title: "W #{SecureRandom.hex(3)}", user: @user)
  end

  def scenario(parent: nil, handed_off_from: nil, status: "active", outcome: nil)
    Scenario.create!(workflow: @wf, user: @user, purpose: "simulation", status: status,
                     started_at: Time.current, parent_scenario: parent,
                     handed_off_from: handed_off_from, outcome: outcome,
                     execution_path: [], results: {}, inputs: {})
  end

  # A frame that handed the run away, as Scenario#hand_off! leaves it: terminal,
  # and carrying the outcome that says which kind of ending this was. The
  # outcome is the load-bearing part — it is how the forward walk tells "this
  # sub-flow handed the run on" from "this sub-flow finished normally".
  def transferred(parent: nil)
    scenario(parent: parent, status: "completed", outcome: "transferred")
  end

  # --- run_origin -------------------------------------------------------------

  test "a run that never left one workflow is its own origin" do
    a = scenario

    assert_equal a, a.run_origin
  end

  test "inside an ordinary sub-flow, the origin is the parent" do
    a = scenario(status: "awaiting_subflow")
    b = scenario(parent: a)

    assert_equal a, b.run_origin, "this is what root_scenario already did, and it must keep doing it"
  end

  test "after a handoff, the origin is the workflow the agent actually started in" do
    a = scenario(status: "completed")
    b = scenario(handed_off_from: a)

    assert_equal a, b.run_origin
  end

  # The case §T 13a names as the one that regresses a shipped feature.
  test "a mixed chain: sub-flow then handoff then sub-flow resolves to the true start" do
    a = scenario(status: "completed")            # started here
    b = scenario(parent: a, status: "completed") # sub-flow of A
    c = scenario(handed_off_from: b, status: "awaiting_subflow") # B handed off to C
    d = scenario(parent: c) # sub-flow of C

    assert_equal a, d.run_origin,
                 "neither link alone spans this: root_scenario stops at C, " \
                 "handed_off_from stops at B"
    assert_equal a, c.run_origin
    assert_equal a, b.run_origin
  end

  # The specific regression 13a warns about: a naive "walk handed_off_from up"
  # returns the sub-flow frame itself, and runner_thread_entries then reads the
  # sub-flow's own path instead of the root's, silently truncating the thread.
  test "an ordinary sub-flow with no handoff anywhere does not become its own origin" do
    a = scenario(status: "awaiting_subflow")
    d = scenario(parent: a)

    assert_not_equal d, d.run_origin,
                     "handed_off_from is nil here, and a naive chain head would stop at D " \
                     "and truncate the transcript to the sub-flow's steps"
    assert_equal a, d.run_origin
  end

  # --- run_head ---------------------------------------------------------------

  test "a run that has not been handed off is its own head" do
    a = scenario

    assert_equal a, a.run_head
  end

  test "the head follows a handoff forward" do
    a = scenario(status: "completed")
    b = scenario(handed_off_from: a)

    assert_equal b, a.run_head
  end

  # §T item 14's second trap, stated explicitly: one hop is not enough, and
  # Success Criterion 1 is "3+ linked workflows".
  test "the head walks the whole handoff chain, not one hop" do
    a = scenario(status: "completed")
    b = scenario(handed_off_from: a, status: "completed")
    c = scenario(handed_off_from: b)

    assert_equal c, a.run_head, "A.handed_off_to is B, and B is terminal — stopping there finds a dead frame"
    assert_equal c, b.run_head
  end

  test "origin and head are the two ends of the same chain" do
    a = scenario(status: "completed")
    b = scenario(handed_off_from: a, status: "completed")
    c = scenario(handed_off_from: b)

    assert_equal a, c.run_origin
    assert_equal c, a.run_head
    assert_equal a, a.run_head.run_origin
  end

  # A cycle would hang the walk. Handoff cycles are refused at publish (SC 5),
  # but a primitive that spins forever on bad data is not one to build four
  # readers on.
  test "neither walk hangs if the data is cyclic" do
    a = scenario(status: "completed")
    b = scenario(handed_off_from: a, status: "completed")
    a.update_columns(handed_off_from_id: b.id)

    Timeout.timeout(5) do
      assert_not_nil a.run_origin
      assert_not_nil a.run_head
    end
  end

  # --- the forward walk has to alternate too ----------------------------------
  #
  # Review finding, 2026-09-05. `run_origin` alternates both links precisely
  # because neither spans a mixed chain — and the forward walk was written
  # without the mirror of that reasoning. `A --sub-flow--> B --handoff--> C`
  # settles BOTH A and B, and it is B that carries `handed_off_to`, not A. So
  # `A.run_head` returned A, which is terminal, and a GET on A rendered a
  # finished run while the agent's work was live in C.
  #
  # The original tests only covered flat handoff chains, which is why this held.

  test "the head is found from a frame whose sub-flow did the handing off" do
    a = transferred                    # was awaiting B, settled by the handoff
    b = transferred(parent: a)         # B handed the run away
    c = scenario(handed_off_from: b)   # the live run

    assert_equal c, a.run_head,
                 "A.handed_off_to is nil — it was B that handed off, and A only waited on B"
    assert_equal c, b.run_head
  end

  # `run_head` follows HANDOFFS forward, and stops at the frame the run was
  # handed to. It deliberately does not descend into that frame's live sub-flow:
  # RunnerShell#runner_step_redirect already has a branch for an active child,
  # and duplicating it here would give two readers of the same fact — which is
  # the pattern this whole primitive exists to remove.
  test "a mixed chain resolves to the same handed-to frame from every frame before it" do
    a = transferred
    b = transferred(parent: a)
    c = scenario(handed_off_from: b, status: "awaiting_subflow")
    _d = scenario(parent: c)

    assert_equal [c, c, c], [a.run_head, b.run_head, c.run_head],
                 "every frame before the boundary agrees which frame the run was handed to"
  end

  test "origin and head are still inverses across a mixed chain" do
    a = transferred
    b = transferred(parent: a)
    c = scenario(handed_off_from: b)

    assert_equal a, c.run_origin
    assert_equal c, a.run_head
  end

  test "an ordinary sub-flow run does not chase a handoff that never happened" do
    a = scenario(status: "awaiting_subflow")
    b = scenario(parent: a)

    assert_equal a, a.run_head,
                 "nothing was handed off here; the run lives where it always did"
    assert_equal b, b.run_head
  end

  # A frame whose handed-to run was abandoned must not be followed into it.
  test "the head ignores a stopped branch" do
    a = scenario(status: "completed")
    dead = scenario(handed_off_from: a, status: "stopped")
    live = scenario(handed_off_from: a)

    assert_equal live, a.run_head,
                 "a stopped branch is not where the run is: #{dead.id} is abandoned"
  end
end
