require "test_helper"

# The regression tests for the handoff tail call.
#
# Written before the feature existed, and kept as its guard. Their reason: three
# review rounds on this subsystem
# produced three criticals, all of one shape — a reader that infers run structure
# from `parent_scenario_id`/`root_scenario` instead of being told it — and every
# one was found by reading code, never by reasoning about the design. A fourth
# and a fifth were found by running these.
#
# Two of them once passed with NO handoff implemented at all, because a
# non-returning sub_flow still descended like an ordinary one and the run did
# land on the target's first step — as a child. The assertions that actually
# separate a tail call from a call are that the handed-to run has no
# `parent_scenario_id`, carries `handed_off_from_id`, and leaves the source
# `terminal?`. "The run reached the next workflow" proves nothing on its own.
#
# Numbering follows § Success Criteria in the design doc.
class HandoffSpikeTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      email: "handoff-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    sign_in @user
  end

  # --- fixtures ---------------------------------------------------------------

  # A workflow that asks one question and then ends.
  def terminal_workflow(title, question_title:)
    wf = Workflow.create!(title: title, user: @user)
    q = Steps::Question.create!(workflow: wf, position: 0, title: question_title,
                                question: "#{question_title}?", variable_name: "v_#{SecureRandom.hex(2)}")
    r = Steps::Resolve.create!(workflow: wf, position: 1, title: "#{title} Done",
                               resolution_type: "success")
    Transition.create!(step: q, target_step: r, position: 0)
    wf.update!(start_step: q)
    [wf, q, r]
  end

  # A workflow whose last step hands off to `target` instead of returning.
  #
  # `sub_flow_returns: false` is the spike's flag. A handoff step has no
  # transitions — that is what makes it a tail call rather than an edge, and it
  # is also why WorkflowHealthCheck will call it a dead end (SC 8).
  def handing_off_workflow(title, target:, question_title: "First")
    wf = Workflow.create!(title: title, user: @user)
    q = Steps::Question.create!(workflow: wf, position: 0, title: question_title,
                                question: "#{question_title}?", variable_name: "carried")
    ho = Steps::SubFlow.create!(workflow: wf, position: 1, title: "Continue in #{target.title}",
                                sub_flow_workflow_id: target.id, sub_flow_returns: false)
    Transition.create!(step: q, target_step: ho, position: 0)
    wf.update!(start_step: q)
    [wf, q, ho]
  end

  def start_run(workflow, step)
    Scenario.create!(workflow: workflow, user: @user, purpose: "simulation", status: "active",
                     started_at: Time.current, current_node_uuid: step.uuid,
                     execution_path: [], results: {}, inputs: {})
  end

  def answer(scenario, value = "yes")
    post next_step_scenario_path(scenario), params: { answer: value },
                                            headers: { "Accept" => "text/vnd.turbo-stream.html" }
  end

  # --- SC 4a — the run actually moves ----------------------------------------
  #
  # The sharpest of the four. BOTH earlier drafts of this design produced a
  # feature that validated and did nothing: the handoff was recorded and the
  # agent was shown "This run is complete". So this assertion is the one that
  # proves the tail call is a tail call and not an ending with extra bookkeeping.

  test "SC4a: answering the handoff lands on the next workflow's first step in the same POST" do
    target, target_q, = terminal_workflow("Target", question_title: "Second")
    source, source_q, = handing_off_workflow("Source", target: target)
    run = start_run(source, source_q)

    answer(run)

    assert_response :success
    assert_match(/Second/, response.body,
                 "the handed-to workflow's first answerable step has to be on screen, in this response")
    assert_no_match(/run is complete/i, response.body,
                    "a handoff is not an ending — this is the failure both earlier drafts shipped")
    handed_to = Scenario.find_by(workflow: target, user: @user)
    assert_not_nil handed_to, "a run should exist on the target workflow"
    assert_equal target_q.uuid, handed_to.current_node_uuid

    # SPIKE FINDING: everything above this line passes with NO handoff
    # implemented at all, because a non-returning sub_flow still descends like
    # an ordinary one — the run lands on the target's first step as a *child*.
    # So the assertions that actually distinguish a tail call from a call are
    # these, and without them this test would have green-lit a no-op feature.
    # That is the same "validated and did nothing" failure the design doc says
    # both earlier drafts shipped, reproduced here in test form.
    assert_nil handed_to.parent_scenario_id,
               "a handoff is not a call: nobody is waiting to be returned to"
    assert_equal run.id, handed_to.handed_off_from_id,
                 "the target should record where the run came from, not who is waiting for it"
    assert_predicate run.reload, :terminal?,
                     "the source half is finished — it handed the run away and will never resume"
    assert_not_equal "awaiting_subflow", run.status
  end

  # --- SC 4 — the handed-to ending is shown -----------------------------------
  #
  # ScenarioSettler.auto_processable? walks past a resolve when
  # `scenario.parent_scenario_id.present?` — "has a parent means its ending is
  # internal". If the handed-to scenario keeps that FK, its ending is swallowed
  # and the agent never sees the run finish.

  test "SC4: the handed-to workflow's ending is shown, not auto-processed away" do
    target, _tq, target_resolve = terminal_workflow("Target", question_title: "Second")
    source, source_q, = handing_off_workflow("Source", target: target)
    run = start_run(source, source_q)

    answer(run)
    handed_to = Scenario.find_by(workflow: target, user: @user)
    answer(handed_to)

    assert_not ScenarioSettler.auto_processable?(handed_to.reload, target_resolve),
               "the ending of the workflow the agent was handed to is the run's ending, " \
               "not a sub-flow's internal one"
    assert_match(/Target Done/, response.body, "the agent has to see the run finish")
  end

  # --- SC 4b — a GET on the abandoned half goes forward -----------------------
  #
  # Refresh, browser Back, or a bookmark on the handed-off-from scenario. The
  # run no longer lives there. It must not show that half's results as if the
  # run ended in it.

  test "SC4b: a GET on the handed-off-from scenario redirects forward to the live run" do
    target, = terminal_workflow("Target", question_title: "Second")
    source, source_q, = handing_off_workflow("Source", target: target)
    run = start_run(source, source_q)

    answer(run)
    handed_to = Scenario.find_by(workflow: target, user: @user)

    # Same caveat as SC4a: this redirect already happens for an ordinary
    # sub-flow (a parent forwards into its active child), so the assertion only
    # means something once the source is terminal and has no active child.
    assert_predicate run.reload, :terminal?, "precondition: the source half is finished"
    assert_nil run.active_child_scenario, "precondition: there is no child to forward into"

    get step_scenario_path(run)

    assert_redirected_to step_scenario_path(handed_to),
                         "the abandoned half must point forward, not render its own results"
  end

  # --- §N — a handoff inside a sub-flow does not leave the parent resumable ---
  #
  # A → sub-flow B → handoff C. B never returns, so A is not waiting for
  # anything any more. If A stays resumable, the run has two live heads and
  # `process_subflow_completion` can resurrect A from a completed child — the
  # `scenario.rb:314` failure, twice found.

  test "N: A -> sub-flow B -> handoff C must not leave A resumable" do
    c, = terminal_workflow("C", question_title: "Third")
    b, b_q, = handing_off_workflow("B", target: c, question_title: "Second")

    a = Workflow.create!(title: "A", user: @user)
    a_q = Steps::Question.create!(workflow: a, position: 0, title: "First",
                                  question: "First?", variable_name: "av")
    a_sf = Steps::SubFlow.create!(workflow: a, position: 1, title: "Into B",
                                  sub_flow_workflow_id: b.id)
    a_r = Steps::Resolve.create!(workflow: a, position: 2, title: "A Done", resolution_type: "success")
    Transition.create!(step: a_q, target_step: a_sf, position: 0)
    Transition.create!(step: a_sf, target_step: a_r, position: 0)
    a.update!(start_step: a_q)

    run = start_run(a, a_q)
    answer(run)                                    # into B
    b_run = Scenario.find_by(workflow: b, user: @user)
    assert_not_nil b_run, "the sub-flow should have opened"
    assert_equal b_q.uuid, b_run.current_node_uuid

    answer(b_run)                                  # B hands off to C

    assert_not_predicate run.reload, :parked?,
                         "A is not waiting for anything — B handed the run away and will never return"
    assert_not_equal "awaiting_subflow", run.reload.status,
                     "A cannot sit awaiting a sub-flow that has left"
    assert_not_nil Scenario.find_by(workflow: c, user: @user), "the run should now live on C"
  end

  # --- the run header names the workflow the agent is in now ------------------
  #
  # Decided 2026-09-05 (design doc Open Q2). The run header flips at the
  # boundary, because on a live call what matters is which script you are
  # following. The transcript stays continuous underneath it.
  #
  # Why this needs a stream rather than falling out of the redirect: the answer
  # is a Turbo Stream that replaces only the thread tail, so without an explicit
  # update the header keeps naming the previous workflow for the whole rest of
  # the run — a fresh GET already renders it correctly, which is how the app
  # came to answer this question both ways in one session.

  test "the run header flips to the handed-to workflow in the same response" do
    target, = terminal_workflow("Target", question_title: "Second")
    source, source_q, = handing_off_workflow("Source", target: target)
    run = start_run(source, source_q)

    answer(run)

    header = response.body[%r{target="runner-workflow-title"><template>(.*?)</template>}m, 1].to_s

    assert_equal "Target", header.strip,
                 "the header is outside the thread, so the stream has to rename it explicitly"
  end

  test "an ordinary sub-flow does not flip the header" do
    child = Workflow.create!(title: "Inner", user: @user)
    cr = Steps::Resolve.create!(workflow: child, position: 0, title: "Inner Done",
                                resolution_type: "success")
    child.update!(start_step: cr)

    parent = Workflow.create!(title: "Outer", user: @user)
    pq = Steps::Question.create!(workflow: parent, position: 0, title: "First",
                                 question: "First?", variable_name: "pv")
    sf = Steps::SubFlow.create!(workflow: parent, position: 1, title: "Into Inner",
                                sub_flow_workflow_id: child.id)
    pr = Steps::Resolve.create!(workflow: parent, position: 2, title: "Outer Done",
                                resolution_type: "success")
    Transition.create!(step: pq, target_step: sf, position: 0)
    Transition.create!(step: sf, target_step: pr, position: 0)
    parent.update!(start_step: pq)

    run = start_run(parent, pq)
    answer(run)

    header = response.body[%r{target="runner-workflow-title"><template>(.*?)</template>}m, 1].to_s

    assert_equal "Outer", header.strip,
                 "a sub-flow is internal to the run; the agent has not changed script, " \
                 "so the header keeps naming the workflow they started in " \
                 "(\"Inner\" still appears elsewhere in the stream, as the sub-flow marker)"
  end

  # --- a handed-off run cannot be rewound out of the handoff ------------------
  #
  # Review finding, 2026-09-05. `ScenarioNavigator#go_back` flips a scenario back
  # to `active` and restores its previous node, and nothing stopped it doing that
  # to a frame the run had already left. That produced a source sitting at
  # `status: "active"` while still carrying `outcome: "transferred"`, and
  # answering it again spawned a SECOND handed-to run alongside the live one —
  # two live branches of one run, with `handed_off_to` picking between them
  # arbitrarily.
  #
  # Not reachable from a single tab, because after the handoff the open card
  # belongs to the target and its history is empty. Reachable by a direct POST,
  # and by a stale second tab still showing the source.

  test "a run that has been handed off refuses to go back" do
    target, = terminal_workflow("Target", question_title: "Second")
    source, source_q, = handing_off_workflow("Source", target: target)
    run = start_run(source, source_q)
    answer(run)

    before = run.reload.attributes.slice("status", "outcome", "current_node_uuid")

    post back_scenario_path(run)

    assert_equal before, run.reload.attributes.slice("status", "outcome", "current_node_uuid"),
                 "the run is not here any more; rewinding this frame reopens a half it already left"
    assert_predicate run, :terminal?

    # And it must SAY so. A refusal with no markup of its own is
    # indistinguishable from a Back that worked — the first version of this
    # guard set a flash that the back stream had no block to render, so the
    # thread silently redrew and the agent learned nothing.
    assert_match(/runner-thread__notice/, response.body,
                 "the refusal has to reach the page")
    assert_match(/continued in another workflow/i, response.body)

    # The notice is prepended after the thread is replaced. Prepending first
    # puts it inside the element the replace then throws away.
    assert_operator response.body.index("runner-thread__notice"), :>,
                    response.body.index('action="replace"'),
                    "a notice streamed before the replace is discarded with the old thread"
  end

  test "going back does not fork the run into two live branches" do
    target, = terminal_workflow("Target", question_title: "Second")
    source, source_q, = handing_off_workflow("Source", target: target)
    run = start_run(source, source_q)
    answer(run)

    post back_scenario_path(run)
    answer(run)

    live = Scenario.where(handed_off_from_id: run.id).where.not(status: "stopped")

    assert_equal 1, live.count,
                 "one run has one live head: #{live.pluck(:id, :status).inspect}"
  end

  # --- SC 6 — export/import round-trips a terminal handoff --------------------
  #
  # A handoff step has no transitions: that is what makes it a tail call rather
  # than an edge. But the dialect requires transitions on every non-resolve step
  # and the published schema puts `minItems: 1` on them, so before this the app
  # exported a file it would refuse to read back — the same class of defect as
  # the two round-trip exceptions already documented in AGENTS.md.

  def exported_document(workflow)
    {
      schema_version: ImportSchemaGenerator::SCHEMA_VERSION,
      exported_at: Time.current.iso8601,
      workflows: [{
        title: workflow.title, description: "", groups: [], folder: nil, tags: [],
        start_step_id: workflow.start_step&.uuid || workflow.steps.first&.uuid,
        steps: StepSerializer.call(workflow, dialect: :strict)
      }]
    }.to_json
  end

  test "SC6: a workflow ending in a handoff exports to a file the app accepts" do
    target, = terminal_workflow("Target", question_title: "Second")
    source, = handing_off_workflow("Source", target: target)
    target.update!(status: "published")

    report = StrictImportValidator.new(user: @user, content: exported_document(source)).validate

    assert_predicate report, :valid?,
                     "the app must be able to read back what it just wrote: #{report.errors.inspect}"
  end

  test "SC6: the flag survives the strict round trip, not just the lenient one" do
    target, = terminal_workflow("Target", question_title: "Second")
    source, = handing_off_workflow("Source", target: target)
    target.update!(status: "published")

    content = exported_document(source)
    report = StrictImportValidator.new(user: @user, content: content).validate
    assert_predicate report, :valid?, report.errors.inspect

    result = WorkflowImporter.new(@user, format: :json, content: content, strict_report: report).call
    assert_predicate result, :success?, result.errors.inspect

    imported = result.workflow.steps.find { |s| s.is_a?(Steps::SubFlow) }
    # `refute` rather than `assert_equal false` only because the column is
    # NOT NULL, so nil is not a third possibility here.
    assert_not imported.sub_flow_returns,
               "a handoff that comes back as a returning sub-flow is a silently different workflow"
  end

  # The exemption must be scoped to the flag, not to the step type. Fed as a
  # literal document rather than an exported workflow, because this shape cannot
  # be saved at all — GraphValidator refuses it, which is the point.
  test "an ordinary sub_flow with no transitions is still refused" do
    target, = terminal_workflow("Target", question_title: "Second")
    target.update!(status: "published")

    doc = {
      schema_version: "1",
      workflows: [{
        title: "Ordinary", start_step_id: "sf",
        steps: [
          { id: "sf", type: "sub_flow", title: "Into Target",
            target_workflow_title: "Target", sub_flow_returns: true },
          { id: "done", type: "resolve", title: "Done", resolution_type: "success" }
        ]
      }]
    }.to_json

    report = StrictImportValidator.new(user: @user, content: doc).validate

    assert_not report.valid?,
               "the exemption is for a tail call only — a returning sub-flow that goes nowhere " \
               "is still the dangling step the rule was written for"
    assert_includes report.errors.pluck(:code), "missing_transitions"
  end

  # --- a handoff that kept its transitions ------------------------------------
  #
  # Review finding, 2026-09-05. Authorable in the builder: add a Sub-Flow,
  # connect it to a next step, THEN untick "come back". Nothing clears the
  # transition. It publishes clean — GraphValidator treats any handoff as a legal
  # terminal — and the runtime ignores the transitions correctly, but export
  # emits them and the strict path then refuses the file with
  # `unexpected_transitions`. That would be a third round-trip exception, so it
  # is surfaced where the other authoring problems are instead.

  test "a handoff that still carries transitions is flagged" do
    target, = terminal_workflow("Target", question_title: "Second")
    source, source_q, handoff = handing_off_workflow("Source", target: target)
    tail = Steps::Resolve.create!(workflow: source, position: 2, title: "Unreachable",
                                  resolution_type: "success")
    Transition.create!(step: handoff, target_step: tail, position: 0)
    source.update!(start_step: source_q)

    issues = WorkflowHealthCheck.new(source.reload).call.issues[handoff.uuid] || []

    assert_includes issues.pluck(:code), :handoff_has_transitions,
                    "it exports to a file the app then refuses to read back"
  end

  test "a handoff with no transitions is not flagged" do
    target, = terminal_workflow("Target", question_title: "Second")
    source, _q, handoff = handing_off_workflow("Source", target: target)

    issues = WorkflowHealthCheck.new(source).call.issues[handoff.uuid] || []

    assert_not_includes issues.pluck(:code), :handoff_has_transitions
  end

  # --- SC 8 — the health panel must not call a handoff a dead end -------------

  test "SC8: the health panel does not offer add_resolve_after on a handoff step" do
    target, = terminal_workflow("Target", question_title: "Second")
    source, _q, handoff = handing_off_workflow("Source", target: target)

    issues = WorkflowHealthCheck.new(source).call.issues[handoff.uuid] || []

    assert_empty issues.select { |i| i[:fix_type] == "add_resolve_after" },
                 "a handoff step ends the workflow on purpose; it is not a dead end to be fixed"
  end

  # The other half of SC 8, and the one that actually bites. `add_resolve_after`
  # stopped firing for free when GraphValidator learned the flag, but the
  # step-level "no outgoing connections" check is independent of the validator
  # and still flagged a handoff — offering a `connect_next` Fix button that would
  # ADD a transition to a tail call, which is precisely what makes it not one.
  test "SC8: a handoff is not flagged as a dead end" do
    target, = terminal_workflow("Target", question_title: "Second")
    source, _q, handoff = handing_off_workflow("Source", target: target)

    issues = WorkflowHealthCheck.new(source).call.issues[handoff.uuid] || []

    assert_empty issues.select { |i| i[:fix_type] == "connect_next" },
                 "a Fix button that adds a transition to a handoff corrupts it"
    assert_empty issues.select { |i| i[:message].to_s.match?(/dead end/i) },
                 "having no outgoing connections is the definition of a tail call, not a fault"
  end

  test "a returning sub_flow with no connections is still a dead end" do
    target, = terminal_workflow("Target", question_title: "Second")
    source = Workflow.create!(title: "Ordinary", user: @user)
    sub = Steps::SubFlow.new(workflow: source, position: 0, title: "Into Target",
                             uuid: SecureRandom.uuid, sub_flow_workflow_id: target.id)
    sub.save!(validate: false)

    issues = WorkflowHealthCheck.new(source).call.issues[sub.uuid] || []

    # The fix type moved from connect_next to add_resolve_after when the
    # dead-end issue absorbed the terminal-not-Resolve finding: its Fix has to
    # work when there is no next step to connect to. What this test guards is
    # the contrast with the handoff above — a *returning* sub-flow with nowhere
    # to come back to is a fault and must be flagged with a working fix — so it
    # asserts fixability rather than one particular remedy.
    assert_predicate issues.select { |i| i[:fixable] }, :any?,
                     "it will come back and has nowhere to come back to — the warning is right here"
  end

  # --- Wave 1 item 4 — a handoff chain has no stack ---------------------------
  #
  # MAX_DEPTH measures sub-flow *nesting*. A tail call does not nest, so a flat
  # chain of handoffs must not be refused for a depth that does not exist. The
  # import-time refusal was restored in 4ccee4fd, which makes this live.

  # SC 5 — the other half of W1.4, and revised from its original claim. It used
  # to assert that a handoff cycle is ALWAYS refused as :circular_subflow —
  # "Depth must stop counting handoff hops; cycle detection must NOT." That
  # premise is exactly what this feature reversed on purpose: a handoff leaves
  # no stack frame (Scenario#hand_off! settles the current frame rather than
  # pushing one, and spawn_target creates the next scenario with
  # parent_scenario: nil), so a pure-handoff cycle does not grow without bound
  # the way a returning cycle does, and is no longer refused as circular. The
  # real hazard a handoff cycle can still have is never reaching a Resolve at
  # all, which is what validate_escapable_across_workflows checks directly,
  # reporting :no_resolve_across_workflows instead.
  #
  # Both halves matter here. The original test's first assertion
  # (`assert_not validator.valid?`) kept passing after the reversal landed,
  # but for the wrong reason — it was true only because neither workflow in
  # that fixture has a Resolve anywhere, so :no_resolve_across_workflows fires
  # in place of :circular_subflow. A fix that only deleted the second
  # assertion would have left this test green while asserting nothing about
  # the actual reversal, so this covers both outcomes: an unescapable cycle is
  # still refused (under the new code), and an escapable one is now accepted.
  test "SC5: a handoff cycle is refused only when it can never reach a Resolve" do
    a = Workflow.create!(title: "Cycle A, unescapable", user: @user)
    b = Workflow.create!(title: "Cycle B, unescapable", user: @user)
    Steps::SubFlow.create!(workflow: a, position: 0, title: "To B",
                           sub_flow_workflow_id: b.id, sub_flow_returns: false)
    Steps::SubFlow.create!(workflow: b, position: 0, title: "To A",
                           sub_flow_workflow_id: a.id, sub_flow_returns: false)

    unescapable = SubflowValidator.new(a.id)

    assert_not unescapable.valid?, "neither side of this cycle can ever reach a Resolve"
    assert_predicate unescapable.findings.select { |f| f.code == :no_resolve_across_workflows }, :any?,
                     "the refusal must name the real hazard: no reachable Resolve"
    assert_empty unescapable.findings.select { |f| f.code == :circular_subflow },
                 "a pure-handoff cycle leaves no stack frame, so it is not circular by itself"

    c = Workflow.create!(title: "Cycle C, escapable", user: @user)
    d = Workflow.create!(title: "Cycle D, escapable", user: @user)
    Steps::SubFlow.create!(workflow: c, position: 0, title: "To D",
                           sub_flow_workflow_id: d.id, sub_flow_returns: false)
    # Position 0 so it is `steps.first` — workflow_self_escapable? falls back
    # to the first step when start_step is unset, same as the unescapable
    # pair above, so this needs no explicit start_step and no graph-structure
    # validation (which would otherwise demand "To C" be reachable from it).
    Steps::Resolve.create!(workflow: d, position: 0, title: "Resolved in D",
                           resolution_type: "success")
    Steps::SubFlow.create!(workflow: d, position: 1, title: "To C",
                           sub_flow_workflow_id: c.id, sub_flow_returns: false)

    escapable = SubflowValidator.new(c.id)

    assert_predicate escapable, :valid?,
                     "D can reach a Resolve on its own, so the cycle through it can too: #{escapable.errors.join(' | ')}"
  end

  test "W1.4: a flat handoff chain longer than MAX_DEPTH is not refused for depth" do
    depth = SubflowValidator::MAX_DEPTH + 3
    workflows = (0...depth).map { |i| Workflow.create!(title: "Hop #{i}", user: @user) }

    workflows.each_with_index do |wf, i|
      if i == depth - 1
        r = Steps::Resolve.create!(workflow: wf, position: 0, title: "End", resolution_type: "success")
        wf.update!(start_step: r)
      else
        ho = Steps::SubFlow.create!(workflow: wf, position: 0, title: "Continue",
                                    sub_flow_workflow_id: workflows[i + 1].id, sub_flow_returns: false)
        wf.update!(start_step: ho)
      end
    end

    validator = SubflowValidator.new(workflows.first.id)
    validator.valid?

    assert_empty validator.findings.select { |f| f.code == :max_depth_exceeded },
                 "a handoff has no stack frame, so a chain of them has no nesting depth to exceed"
  end
end
