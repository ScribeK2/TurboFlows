# The runner: RunnerShell, Scenario mode and Player mode

> Part of the agent guidance for TurboFlows, and as binding as `AGENTS.md`, which indexes it.
> Moved here verbatim from `AGENTS.md` on 2026-09-20 so it loads only when the work needs it.
> Cross-references written as "Builder UI §…" mean `docs/agents/builder.md`; "Workflow Engine" and
> "key-services entry" mean `docs/agents/workflow-engine-and-import.md`.

## RunnerShell

**Key concern:** `RunnerShell` (`app/controllers/concerns/runner_shell.rb`) — the
run itself, shared by `ScenariosController` and `PlayerController`. It owns where
a GET belongs (`runner_step_redirect`), which step is open
(`assign_runner_step_state`), and what an answer does (`advance_runner`,
`rewind_runner`, `respond_to_settled`). Template method pattern: each controller
implements `runner_step_path` and `runner_results_path`, and nothing else about
the run.

It replaced `SubflowOrchestration`, which redirected around sub-flow boundaries
after each outcome — `ScenarioSettler` crosses those boundaries itself and reports
where the run came to rest, so there is nothing left to orchestrate. It was called
`RunnerAdvance` for as long as it owned only the POST; the GET half was still
written twice and had drifted into five disagreements about the same run (see
`test/integration/runner_shell_parity_test.rb`, which names each one).

**What is left in the two controllers is what is genuinely different:** their
URLs, their layouts, and who is allowed in. Nothing about run semantics belongs in
either — if you are about to add an `if` about the run to a controller, it goes in
the concern.

## Player Mode

The Player is the user-facing workflow execution UI, separate from the builder's Scenario mode. It has its own layout, routes, and controller.

**The standalone layout covers the runs, not the whole controller.** `/play` is a
browse page and renders the application layout, top bar and all; `step`, `show`
and `show_shared` render `layouts/player`. See `PlayerController#resolve_layout`.

**Routes:** `/play` (index), `/play/:id` (start), `/player/scenarios/:id/step` (step), `/player/scenarios/:id/show` (completion), `/s/:share_token` (shared anonymous access)

**Key files:**
- `app/controllers/player_controller.rb` — start, step, next_step, back, show, show_shared
- `app/views/layouts/player.html.erb` — standalone layout (header, main, footer)
- `app/views/player/step.html.erb` — a thin shell: page chrome plus route-shaped locals, delegating everything below to `runner/_thread`
- `app/views/player/show.html.erb` — completion screen with stats
- `app/views/player/index.html.erb` — the workflow list. Renders in the **application** layout, and uses the app's `page-header-section` heading rather than a Player-specific one
- `app/helpers/player_helper.rb` — `player_back_button` helper (uses Player routes, not Scenario routes)
- `app/assets/stylesheets/_player.css` — Player-specific layout and component styles

**Key differences from Scenario mode:** only the shell differs. Both runners
render `app/views/runner/_thread`, and through it `runner/_step_body`, which
never calls a route helper — everything route-shaped (`next_url`, `stop_url`,
`back_button`, `show_cancel`) arrives as a local. Add runner behaviour in the
partials, not in a shell. Both shells are now branchless: neither contains an
`if` about how to render the run.

- Uses `player_scenario_*_path` routes, not `*_scenario_path` routes
- Its own layout (`layouts/player.html.erb`) and page chrome — for the run screens; the index is an app-shell page
- Cancel is hidden when nobody is signed in (`show_cancel: current_user.present?`),
  because `stop` is **not** in `PlayerController`'s `authenticate_user!` skip
  list — an anonymous visitor clicking it would be bounced to a sign-in page.
  The gate is the session, not `shared_access`: a signed-in user does get Cancel
  on a shared run. And Cancel does not return anywhere in the nav — it POSTs to
  `stop`, which settles the whole scenario tree and redirects to the **results
  screen** for the run's origin (`run_origin`), the same place a completed run ends.
  It said "root scenario" until 2026-09-12, which was right until handoffs: a
  handed-to frame is its own root, so Cancel after a handoff reported only the
  last workflow. Both results pages redirect any other frame to the origin, and
  read how the run ended — status, resolution, finish time — from
  `Scenario#run_ending`, not from the origin, whose outcome after a handoff is
  just `transferred`. `run_ending` is not `run_head`: `run_head` skips stopped
  branches, so from the origin of a run cancelled after a handoff it stops on
  the transferred frame before the one the agent stopped
- **A share-link run belongs to the visitor, or to nobody — never to the owner.** `show_shared` stamped `user: @workflow.user`, so every anonymous run was recorded as the owner's, and `AnalyticsController#build_agent_stats` groups by `users.email` — an editor who shared one workflow widely appeared to be the busiest agent in the organisation. `scenarios.user_id` is now **nullable**: NULL says what is true, where naming the owner was a lie with a consumer. A signed-in visitor following a share link is a real agent and is recorded as one. Rejected: a sentinel "Anonymous" user, which keeps the constraint at the cost of a fake account in the admin user list and the agent filter, with every reader still having to know it is special. No reader needed changing — `build_agent_stats` uses `joins(:user)`, an INNER JOIN, so anonymous runs drop out of per-agent figures on their own; the CSV export already wrote `scenario.user&.email`; sub-flow children inherit the parent's user, so nil propagates; and the `current_user.scenarios` lookups are Scenario-mode, which always has a user
- Both runners operate on AR Step objects with method access (`step.title`), not
  execution-path hashes. `step['field']` access was removed in the shared-partial
  extraction; `execution_path` hashes remain only in the results view and in the
  thread's cards.

**The run renders as a thread, and that is the only rendering.** Answering a step
collapses it into a compact card and appends the next one below it, streamed — no
navigation, so the transcript the agent is reading stays put. `runner/_thread`
renders the answered cards and delegates the open one to `runner/_thread_card`; the tail
(`runner/_thread_tail`) is whatever the run is waiting on — the open card, a
Resume control, or the ending — and always carries `id="runner-card-current"`, so
a streamed answer always has a target to replace.

This shipped behind `STACKED_RUNNER` and the flag was removed on 2026-08-29 once
the thread had carried real traffic. There is no second runner and no config to
render one; `runner/_trail` and the classic one-card-at-a-time branches are gone.

**No step numbers or progress bars.** Both were removed deliberately: two
numbering systems disagreed inside sub-flows, and the bars divided by
`workflow.steps.count`, which a branched run never visits in full. The thread's
cards carry that orientation now, read from the root scenario. See UIGUIDE.md
§ Surfaces Deliberately Excluded for the reasoning.

**A refusal is announced through the card's own live region.** The card is
replaced wholesale by the answer's stream (`turbo_stream.replace
"runner-card-current"`), so the markup holding the messages — `runner/_errors`
and the per-field `.form-error` in `scenarios/_form_step` — is a NEW element
every time and cannot be a live region itself; rendering an empty one up front
would change nothing. What carries them is the `aria-live="polite"` region
inside the card, filled by `scenario-step#connect` AFTER the card is in the
document. `_thread_card` passes the messages as
`data-scenario-step-refusal-value`, and the controller announces that instead
of the step's title when it is present — never both, since the agent asked for
one and is being told the other. Focus goes to the refused control (`.is-invalid`)
rather than the first input, and the announcement follows it by a frame: moving
focus makes a screen reader speak the newly focused control, which would cut off
a polite announcement made before it. `scenario-step#focusFirstControl` picks the refused
control, else the `input` target (a question's single answer control), else the
first real control in the form — that last fallback is what a FORM step needs,
since it renders its fields from the step's own definition and carries no
`input` target, so it used to focus nothing and a keyboard agent tabbed in from
the top of the page every time. `:not([type=hidden])` is load-bearing there:
`form_with` emits its token first, and focusing a hidden input silently does
nothing. **Still not routed this way: a HALT**
(`flash.now[:alert]`), which prepends its own `role="alert"` row to the
persistent `#runner-thread` — a newly inserted alert, which is a different
mechanism with its own reliability. None of this is verified against a real
screen reader.

**Auto-advance has one source of truth:** `RunnerHelper#runner_auto_advances?`.
It drives both the Stimulus value on the shell and whether Continue renders in
the partial. Those must agree — when they didn't, a question with options and an
unexpected `answer_type` rendered radio cards with no way to submit.
