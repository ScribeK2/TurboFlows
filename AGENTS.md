# AGENTS.md

This file provides guidance to AI coding agents working with TurboFlows.

## What is TurboFlows?
A straightforward workflow creator for call/chat centers to build, simulate, and manage post-onboarding training + client troubleshooting flows with drag-and-drop simplicity.

- Seven step types: Question, Action, Sub-Flow, Message, Escalate, Resolve, Form
- **A Sub-Flow either returns or hands the run over.** `steps.sub_flow_returns` defaults to `true`, which is the call/return behaviour that has always existed: a child `Scenario` is spawned, its results merge back, and the parent resumes at `resume_node_uuid`. Set it `false` and the step is a **tail call** — the run moves to the target workflow and never comes back, so the step ends this workflow, takes **no transitions**, and needs no Resolve after it. That is why a workflow can now *point* a user at another one instead of dead-ending. Concretely, a handoff differs everywhere the run's shape is read: `Scenario#hand_off!` settles this frame **and every ancestor still waiting on it** (`status: "completed"` + `outcome: "transferred"` — terminality and *how it ended* on separate columns, so reporting can tell a handoff from a completion); the handed-to scenario carries `handed_off_from_id` and **no** `parent_scenario_id`, because nobody is waiting for it; `GraphValidator` accepts it as a legal terminal; `SubflowValidator` exempts it from `MAX_DEPTH` (a tail call leaves no stack frame) **and from cycle detection** — a cycle is refused only when *every* edge in it is a returning call, because `hand_off!` settles the whole waiting ancestor chain, so a mixed cycle does not nest either. Mutual routing between workflows is therefore legal, and the hazard that blanket rule had been catching by accident is now caught deliberately by a cross-workflow escapability check (`:no_resolve_across_workflows`): seed from the workflows that reach a real Resolve unaided, spread backward along handoff edges, and refuse whatever is left. Only reached when the graph actually contains a handoff — with none, `GraphValidator`'s own `:no_path_to_resolve` already answers the question. And `WorkflowHealthCheck` does not call it a dead end
- **Two primitives answer "where does this run live", and nothing should infer it again.** `Scenario#run_origin` walks backward to the workflow the agent started in, alternating `root_scenario` and `handed_off_from`; `Scenario#run_head` walks forward along `handed_off_to` to the frame the run is on now. Neither link alone spans a mixed chain (`A --sub-flow--> B --handoff--> C --sub-flow--> D`), and one hop forward is not enough because the next frame may itself have handed on. `root_scenario` still answers the narrower question — the top of one *parent* chain — and is correct for "which script am I following", which is what the run header uses. Use `run_origin` for anything about the run as a whole: the transcript, and share/embed permission (the token belongs to the workflow the visitor opened, and a handed-to workflow has none). Four readers each derived this for themselves before, and three review rounds plus a spike each found a different one wrong — twice at the same line.
- All workflows are graphs — every step connects via explicit Transitions (no separate "linear mode")
- Every workflow must have at least one Resolve step (the only always-terminal type)
- Scenario Mode: interactive step-by-step graph traversal with variable interpolation {{var}}, sub-flow recursion, safety limits
- Player Mode: user-facing workflow execution UI for agents on live calls/training. Separate layout, share links, embed mode. Shares the step body with Scenario mode via `app/views/runner/` partials
- Sharing: workflows can generate share tokens (`/s/:share_token`) for anonymous access, with optional iframe embedding
- Tags: workflow categorization with tag pills, autocomplete, and search integration
- Real-time collaboration via Action Cable (WorkflowChannel presence)
- Hierarchical Groups (up to 5 levels) + Folders + drag-and-drop organization
- Workflow templates: YAML-driven archetypes (`WorkflowTemplate`) loaded from `config/templates.yml` (5 presets: Guided Decision, Verification Checklist, Triage & Escalate, Diagnosis Flow, Simple Handoff)
- Import/export (JSON/CSV/YAML/MD → JSON/PDF via Prawn). JSON and YAML imports carry `groups` (name paths from the root, or a unique group name at any depth), a `folder`, and `tags`, resolved by `WorkflowPlacement` before anything is written and then applied inside the import transaction. Assignment to a parent group covers its children — the same rule `Workflow.visible_to` uses — so an editor who can file under a nested group in the builder can name that group on import. CSV and Markdown are flat formats and carry none of that. Every import lands as `status: "draft"` with no `draft_expires_at` — `WorkflowImporter` nulls the column via `update_all` once, after `apply!`, and `Workflow`'s `set_draft_expiration` callback only stamps/refreshes a draft's TTL when it's a new record or already carries one, so a nil `draft_expires_at` stays nil across every later edit. It won't be swept by `CleanupDraftsJob` and needs an explicit publish
- **Strict AI dialect** — a JSON file carrying a top-level `schema_version: "1"` takes a separate, strict path: `StrictImportValidator` refuses what the lenient parser coerces (unknown step type, unknown field, duplicate/missing/malformed step id, dangling transition target, missing required field, a resolve step with transitions, a non-resolve step without them (except a `sub_flow` with `sub_flow_returns: false`, which ends the workflow and so must have none), invalid enum, invalid condition syntax, unknown/forbidden group, unresolvable sub-flow target) and reports every problem at once with a stable code, a JSON path and what was expected. It writes nothing: an upload renders a preview or an error report, and committing takes a second POST to `/workflows/import/commit`. `ImportSchemaGenerator` generates `public/schemas/turboflows-workflow-v1.json` from `StepFieldMap` and the models' `VALID_*` constants; `ImportPromptGenerator` builds the copyable agent prompt on the import page from that same schema. A file may carry a **set** of up to `ImportSchemaGenerator::MAX_WORKFLOWS_PER_FILE` workflows, imported together in one transaction, so a `sub_flow` step may name another workflow defined in the same file by title rather than needing it to exist and be published first — that chicken-and-egg is why a generated set of linked workflows was previously unimportable. Two workflows in one file may not share a title, since that is how an in-bundle target is matched, and a bundle whose sub-flows form an **all-returning** cycle, exceed `SubflowValidator::MAX_DEPTH` (10), name a target that vanished between preview and commit, or from which **no Resolve is reachable at all** (`:no_resolve_across_workflows`) is refused by `SubflowValidator` after insert and rolled back whole. A cycle of *handoffs* is not refused — that is a normal routing shape. Depth is refused at import even though `WorkflowHealthCheck` files it as a `:warning`, because `Workflow#validate_subflow_circular_references` copies a save-blocking `SubflowValidator` finding onto the record on **every save** — letting a 15-deep chain import produced fifteen workflows that could never be saved or published again. Which findings block a save is now an explicit allowlist, `SubflowValidator::SAVE_BLOCKING_CODES` (`circular_subflow`, `max_depth_exceeded`, `subflow_target_missing`) — an allowlist, not a denylist, so a finding added later is inert at save time until someone opts it in. `:no_resolve_across_workflows` is deliberately absent: a bundle is wired leaf-first and is legitimately inescapable while half-built, so it must stay saveable. Publish and import commit refuse it; the builder shows it as a warning. **A bundle lands as drafts referencing drafts, so publish it leaf-first — and when it references itself, leaf-first does not exist.** Whichever member of a cycle you publish first still points at a draft, which is why `WorkflowSetPublisher` exists: it walks the root's transitive draft dependencies and publishes them in one transaction, with each member carrying the set's ids in `Workflow#publishing_alongside` so `validate_subflow_steps` accepts a target going live in the same breath. That relaxes the rule's *timing*, never the rule — nothing is left pointing at a draft, and handoffs are **not** exempted. Publishing a workflow whose closure is larger than itself redirects to a confirmation page first. `Workflow#validate_subflow_steps` asks for a published sub-flow target only inside `Workflow#while_publishing`, the save `WorkflowPublisher` makes to go live, and so do the graph-structure check and the blank-target check. They keyed on `published?`, which says a workflow is live rather than being published, and a live workflow is edited in place, so its title and Details saves were refused mid-edit; `WorkflowHealthCheck` marks the step `:subflow_target_unpublished` (a warning) so the ordering is visible in the builder rather than arriving as a failed publish. Export emits this dialect, so an exported file is a valid strict import file — with one deliberate exception: a workflow containing a `select` form field with no `select_options` exports to a file the validator refuses (`missing_select_options`). Nothing could write that key before 2026-09-04, so such a field was always an unanswerable dropdown; `WorkflowHealthCheck` flags it as `:select_options_required` on the step so it can be fixed before exporting. There is a second such exception, and it is the price of drafts referencing drafts: a workflow whose sub-flow target is still a draft exports to a file the validator refuses (`sub_flow_target_not_published`), because export emits the target by title and the validator resolves an out-of-bundle title against published workflows only. Publish the target — or export the set together once bundle export exists. A third exception comes from what the builder lets you save: a step with a blank title, or a Question with blank question text, exports to a file the validator refuses (`missing_required_field`). The step panel saves them anyway, because letting the browser refuse the save lost the edit, and neither blocks a publish. `WorkflowHealthCheck` flags them as `:title_required` and `:question_text_required`. A fourth is the same shape: a Form field row autosaves before its `name` or `label` is typed, and the validator refuses a field missing either (`missing_required_field` at `options[i].name` / `.label`) — the published schema always required both, and until 2026-09-18 only the schema said so. `WorkflowHealthCheck` flags it as `:form_field_incomplete`. A workflow ending in a **handoff** does round-trip: `ImportSchemaGenerator` makes `transitions` conditional on `sub_flow_returns` via `if`/`then`/`else`, and the `else` is load-bearing — a *returning* sub_flow with nowhere to go is still refused. A file with no `schema_version` is untouched and keeps the lenient behaviour
- No Node.js: pure Hotwire (Turbo + Stimulus), importmap + Propshaft, vanilla CSS (@layer + OKLCH tokens)
- Rails 8.1, Devise auth (roles: Administrator / Editor / User), optimistic locking (lock_version)

## Development Commands

**Setup (one-time)**
```bash
git clone https://github.com/ScribeK2/TurboFlows
cd TurboFlows
bundle install
rails db:create db:migrate db:seed    # creates DB + seeds initial data (if any)
```

**Run locally**
```bash
bin/dev             # starts Puma + Action Cable → http://localhost:3000
```

**Login**

Sign up with any email/password (Devise). Use seeded/admin account if present in `db/seeds.rb` (check file for credentials).

**Testing (Minitest)**
```bash
bin/rails test                                              # full suite
bin/rails test test/models/workflow_test.rb                 # single file
bin/rails test test/models/workflow_test.rb:42              # single test by line
bin/rails test -v                                           # verbose output
bin/rails test test/system/builder_grow_test.rb             # ONE system file
bin/rails test:system                                       # every system test
```

Four things that have each cost someone an afternoon:
- **`bin/rails test:system TEST=…` ignores the file here** and runs the whole
  directory (several minutes). To run one system file, name it to
  `bin/rails test` as above.
- **Never kill a system run mid-flight.** System tests commit their records
  (`use_transactional_tests = false`), so an interrupted run leaves rows behind
  and later runs fail with fixture foreign-key violations that look exactly like
  a regression. Reload the test DB — `RAILS_ENV=test bin/rails db:drop db:create
  db:schema:load` — rather than debugging the diff.
- **Bullet writes to `log/bullet.log` in the test environment**, not to
  `log/test.log` (`Bullet.bullet_logger = true`, `Bullet.raise = false`); a grep
  of the wrong file finds nothing and proves nothing.
- **A test that clicks inside the builder's step panel must wait for it to
  settle.** The panel animates open over 250ms and its fields re-wrap as it
  widens, so a button found mid-animation moves before the click lands and the
  click hits whatever slid under the old spot — about one run in seven.
  `open_step` / `assert_panel_settled` in `test/application_system_test_case.rb`
  are that wait; `builder_grow_test.rb`'s autosave-race test is the one place a
  wait must NOT be added (between typing the title and pressing "New step" is
  the race), and its mutation check is to make `TransitionSync#call` start with
  `@step.transitions.destroy_all` and confirm the failure lands on the
  transitions assertion, not the title one.

**Database & Utils**
```bash
rails db:reset        # drop/create/migrate/seed
rails console
```

**Deployment**

Kamal: `kamal deploy` (see `config/deploy.yml`). Required env: `RAILS_MASTER_KEY`, `SECRET_KEY_BASE`, PostgreSQL creds.

## Architecture Overview

**Core Domain Models**

- `Workflow` — container with versions (`workflow_version.rb`), autosave, optimistic locking (`lock_version`). Key methods: `sample_variables_for_preview` (preview interpolation), `replace_groups!` (atomic group assignment), `validation_graph_hash` (shared graph validation hash)
- `Step` — STI base class (`app/models/step.rb`); subclasses in `app/models/steps/` (Question, Action, SubFlow, Message, Escalate, Resolve, Form). UUID-based identification (immutable via `attr_readonly`). Includes `Step::Positionable` concern for ordering.
- `Tag` / `Tagging` — workflow categorization (polymorphic tagging)
- `Transition` — directed edges between steps (same workflow only). Supports conditional expressions via `ConditionEvaluator`, simple value matching, and position-ordered evaluation (first match wins).
- `Scenario` — simulation runner. Always uses graph traversal via `StepResolver` and `current_node_uuid` tracking. Spawns child scenarios for sub-flows, enforces iteration limits on circular graphs. Step processing methods (`advance_to_next_step`, `resolve_at_current_step`, `record_completion`) are public API used by `ScenarioStepProcessor`.
- `Group` / `Folder` — hierarchical org (recursive membership, cascade permissions)
- `User` — Devise model with roles (Administrator / Editor / User)
- `WorkflowTemplate` — YAML-driven workflow archetypes loaded from `config/templates.yml`

## Builder UI

The unified builder lives at `workflows/:id` — one URL for both viewing and editing. No separate wizard or editor views.

**Layout:** Header (left = inline-editable title + status, right = Edit/Run Scenario/Publish/Export buttons in `.builder__header-actions`, which wrap onto their own row below 640px) → Toolbar (step count, View Flow, Templates popover, Settings) → Main area (step list + slide-in panel). Empty state shows template archetype cards for quick-start.

**Key views:**
- `_builder.html.erb` — main layout, renders step list + empty Turbo Frame panel
- `_step_list.html.erb` / `_step_row.html.erb` — compact step rows with SortableJS drag-and-drop
- `steps/_panel_edit.html.erb` — step editor loaded via Turbo Frame into the panel
- `steps/_doors.html.erb` — the ways out of the open step, one row each, wired or a stub. Inside the autosave form, so it holds no `<form>`
- `steps/_target_picker.html.erb` — the "Use existing…" `<dialog>`, rendered outside that form because it holds one
- `_flow_diagram_panel.html.erb` — read-only BFS flow diagram in the panel
- `_settings_panel.html.erb` — workflow metadata (description, who can see it, tags, sharing)
- `_health_panel.html.erb` — health validation results (errors, warnings, passing checks with Fix buttons)
- `_empty_state.html.erb` — shown when no steps; includes template archetype cards

**Key Stimulus controllers:**
- `builder_controller.js` — panel open/close, step selection, title autosave, Escape to close, `openHealth` action, auto-opens health panel when `?health=true` URL param is present
- `step_list_controller.js` — SortableJS reorder + the type picker: opening it for a door (from a row's stub or the panel's "New step"), writing the `data-grow-*` fields, and floating it beside its trigger
- `step_target_picker_controller.js` — the "Use existing…" dialog on a door row: which door it is for, the filter, Escape (`stopPropagation`, or the whole panel closes behind it), and closing on `turbo:before-cache`
- `inline_autosave_controller.js` — debounced autosave (2s), listens for `lexxy:change` events, flushes pending saves on disconnect via `FormData` + `fetch`, dispatches `health:check-needed` after disconnect saves
- `step_warnings_controller.js` — async health check fetch, renders inline warning icons on step rows, toolbar issue count, click-to-open popover with Fix buttons. Listens for `turbo:submit-end`, `health:check-needed`, `turbo:before-stream-render`
- `template_picker_controller.js` — template popover in toolbar, applies workflow archetypes

**Autosave pattern:** Every field change triggers `inline-autosave#schedule` (via `data-action` on inputs or `lexxy:change` listener on the form). On disconnect (e.g., switching steps), pending saves are flushed by snapshotting `FormData` and sending via `fetch()` POST with `_method=patch`. The step panel form carries `novalidate`: `requestSubmit()` runs the browser's required-field check, and while any `required` field was empty (a new Question's text, a Form row just added) every save was refused and the edit dropped. The health check says what still needs filling in.

Media is the exception: the panel form is not multipart and never carries file
bytes. A chosen file is direct-uploaded and attached by
`Steps::MediaAttachmentsController`, which answers with `steps/_media_list`.
Every other control must autosave — `test/integration/step_panel_autosave_coverage_test.rb`
renders each step type's panel and refuses one that does not.

**Growing a workflow.** A step is added **from the step it follows**, not
appended and then bound to one in a `<select>`. `GrowStep.create`
(`app/services/grow_step.rb`) writes the step and its incoming edge in one
transaction: it lands at `from_step.position + 1` and everything below shifts
down, so it reads where it runs. A builder-made Question starts as
`answer_type: "yes_no"` with a `variable_name` made unique against the
workflow's other Questions (`untitled_question`, `untitled_question_2`, …)
*before* the save — the model's callback names every "Untitled Question" the
same thing and never renames, so two picker-made Questions shared one variable.
The builder used to select no answer type at all, because a silent default to
Text Input ran and was wrong with nothing on screen saying so; Yes/No is safe
in a way that default was not, because a wrong guess appears at once as two
doors on the row. `GrowStep` is **not** `StepBuilder` — that bulk-writes an
import or a template and demands a Resolve in the payload — and import never
calls it. `GrowStep.connect` wires a door to a step that already exists,
retargeting that door's own edge rather than adding a second one that could
never fire (first match wins). The one `update_column` here is
`assign_start_step`, moved from `StepsController` unchanged: a full save would
bump the workflow's `lock_version` under whatever the title or Details autosave
is holding and be refused as stale. Every grow replaces the **whole** step list
and broadcasts it, because a mid-list insert moves every later ordinal and every
"→ Title · 4" that names one.

**The ways out of a step are computed, never stored.** `Step::Doors`
(`app/models/step/doors.rb`) derives them from the step itself — Yes and No for
a Yes/No Question, one per option for Multiple Choice and Dropdown, a single
"Next" for any other step, and none at all for a Resolve or a handoff, which
nothing can follow — and pairs each with the transition that serves it,
or with nothing, which is a **stub**. A stub is not a row and nothing writes
one. A door is wired only when `StepResolver` would take that transition for
that answer and **no more loosely than that**: two review rounds each found a
looser version — the first stripped backslashes `ConditionEvaluator` did not
then strip, so an option containing an apostrophe read as wired though the
runner could not yet match it; the second stripped quote characters from the
door's own value, which the runner compares raw. Read a condition the way the
runtime reads it, or a stub is a lie. Since 2026-09-19 a well-formed string
comparison's value has two readings — `ConditionEvaluator#parse`'s `:value`
(unescaped) and `:literal_value` (the literal text between the delimiters,
backslashes kept) — and the runner takes an answer matching either one, so
`Doors#operator_match?` checks both too: still no more loosely than the
runner, against a runner that itself grew less strict. What no door claims is
an **extra** (`#extras`); a wired
blank-condition edge is the `fallback`, rendered last as "Anything else", which
is why a stub above it reads `follows “Anything else”` and not "nothing yet".
`#missing` is the answers a run could give that lead nowhere: empty while
the step has no transitions at all, since `:no_outgoing_transitions` already
says that once, and empty again once a fallback is catching them. `#unmatched_extras` is an extra whose condition names a value the
step no longer offers, bare conditions included, because `StepResolver` honours
a bare `modem` too. It **reuses a loaded `transitions` association** when the
caller preloaded one (`includes(transitions: :target_step)`), since `.includes`
on a proxy always re-queries and one `Doors` per row made that a query per step
on every list render. So build it on a fresh or reloaded step after writing
transitions — `@step.reload` — never on one whose association was loaded before
the write.

**Option labels and values are trimmed on save.**
`Steps::Question#default_option_values_to_labels` strips both fields every
time, so a value typed as ` Router ` saves as `Router`. `ConditionEvaluator`
strips the CONDITION's value when it reads one, but compares the ANSWER
raw — and the runner submits an option's saved value, padding included, as
that raw answer — so a padded option value could never equal its own
(already-stripped) condition; see the `ConditionEvaluator` key-services
entry for where that strip happens. No data migration: a value saved with
padding before 2026-09-19 heals on that step's own next save, and
reassigning `options` to a content-equal Array is a no-op for AR's
JSON-column dirty tracking, so re-saving one that was never padded does not
dirty it or bump `lock_version`.

**`TransitionSync` + `transitions.uuid` replaced a save that deleted
everything.** The panel's connection editor used to `destroy_all` a step's
transitions and rebuild them from the JSON the browser held, so an edge written
on the server while the panel was open — one a grow made, one a health fix
added — was wiped by that panel's next autosave, including the flush
`inline-autosave#disconnect` sends as the panel is replaced. Growing from a door
*is* replacing the panel, so the feature deleted its own work. Rows are keyed by
`transitions.uuid` (`crypto.randomUUID()` in the browser — with a
`getRandomValues` fallback for non-secure contexts (plain-http internal
hostnames) — generated by the model for every other writer, `attr_readonly`,
unique). The payload used to be one list, `known`, standing for two different
facts, and that conflation was its own bug: `rendered` is now every uuid the
server actually put in this editor, `minted` is every uuid this editor
invented itself — a row the author added, whether or not it has since saved:
nothing in the JS ever moves a uuid OUT of `minted` on success, only a full
re-render of the fragment starts a fresh `minted` over (see the accepted
residual below, which is exactly this gap). A rendered uuid
missing from `rows` could mean the author removed it here, OR that someone
else's save removed it while this panel sat open, and a single list cannot
tell those apart — which is exactly how a stale second panel used to re-create
a connection someone else deleted: panel B was rendered with `known: [e1]`,
panel A deleted `e1` elsewhere, and B's next autosave (of ANY field — the panel
always submits the whole step) sent `e1` in `known` again, so
`find_or_initialize_by` brought it back.

`TransitionSync#sync_row` is the rule this splits into, scoped to
`@step.transitions` throughout: the delete set is `(rendered + minted) -
rows`; a row that exists is updated; a missing row is created ONLY when its
uuid is in `minted`; a missing row whose uuid is in `rendered` (and only
`rendered`) is left alone and reported in the result's `skipped`, never
created; a uuid in neither list is ignored, since it was never this editor's
to judge; a row whose own target was cleared (as opposed to a row gone
missing) behaves exactly as before — destroyed if it existed, written nowhere
if it didn't — and is never reported skipped, blank-target and stale-panel
being different problems. Scoping cuts both ways: a foreign uuid (another
step's transition) claimed as `minted` fails `Transition`'s own
uuid-uniqueness validation the instant `sync_row` tries to create it, raising
`ActiveRecord::RecordInvalid` — a different exception than the
`ActiveRecord::RecordNotUnique` a genuine two-saves-at-once race raises
(`sync_transitions` rescues both through the same refusal path); claimed as
`rendered` it is correctly never touched, but — the one place the wording is
looser than the behaviour — it is still reported `skipped`, so a payload
naming a step it never actually rendered shows the "removed elsewhere" notice
though nothing was deleted. `TransitionSync.call` returns a `Result`
(`Data.define(:skipped)`), received only by `StepsController#sync_transitions`
— the sole caller of `.call` — which stashes it as `@sync_result` for
`healing_stale_panel?` to consult, so the response-shaping code below can ask
whether this save skipped a row without `sync_transitions` itself growing any
response logic.

A non-empty `skipped` heals the panel: `StepsController#update` re-streams the
WHOLE `dom_id(step, :connections)` fragment plus a `#flash` notice
(`STALE_PANEL_NOTICE`, carried by the HTML redirect and the JSON response too)
— the SERVER never answers a heal silently, since a dropped row with no word
said would read as data loss. One path has nowhere to show it, though:
`inline-autosave#disconnect`'s flush, sent after the panel that made the
request has already been replaced by another. Its `.then` only calls
`Turbo.renderStreamMessage` for a NON-OK response (a refusal); a 200 — which
is what a heal answers with, flash included — is left unrendered, so a heal
that happens to land through that specific path drops the notice with
nothing shown. That heal shares the same one-stream-per-target gate the rename and
door-shape triggers already use (`connections_streamed`), so it never doubles
up with whichever of those already sent the fragment. A pending autosave
already in flight cannot undo the heal: the heal replaces a div INSIDE the
autosave form, so the form element itself is never removed from the DOM and
its `inline-autosave` controller never disconnects — a debounce that fires
afterwards reads the LIVE, now-healed hidden input. Even the one path that
snapshots the form ahead of time — `inline-autosave#disconnect`'s `FormData`
flush, taken when the panel is switched away before the debounce fires —
still lists the gone uuid under `rendered`, never `minted`, so that stale
snapshot hits the same skip branch on the server, not the create one.

The SERVER still reads a payload sending the legacy `{known, rows}` shape
exactly as it always did: `known` never actually gated creation even before
this change (only the delete set), so under this shape a missing row is still
created outright and nothing is ever reported skipped. `rendered`/`minted`
win outright whenever either key is present as an Array, even an empty one,
and `known` is then ignored for both the delete set and the row loop; only
when neither is an Array does the payload fall back to `known`. A payload
that is none of those shapes — an Array, say — is **refused**, never read as
"delete everything": `TransitionSync::Malformed` answers through the refusal
path, which says the truth, that the step's fields saved and its connections
did not.

And the EDITOR still sends `known` — not only reads it. `_transitions_editor.html.erb`
renders `known` alongside `rendered`/`minted`, both the same uuid list, for
one reason: a builder tab open ACROSS A DEPLOY keeps running the pre-2026-09-19
`step_transitions_controller.js` (`javascript_importmap_tags` carries no
`data-turbo-track`, and a builder save or panel open is a stream or frame
load, never a Turbo visit that would refetch it), whose `loadState` reads
only `known`, and whose `addTransition` still pushes a freshly minted uuid
into it. Without a real `known` in the field, that old tab starts with an
empty `known`, so it can still add, edit, and even remove
a row it minted in THIS session (that uuid did make it into `this.known`, via
`addTransition`); what it can never remove is a row the SERVER rendered into
it — any pre-existing connection, which `this.known` never held to begin with
— because removing one still computes an empty delete set. The transition it
"removed" was never actually deleted, and the server's `door_shape_changed?`
backward check (reading the same empty `known` through
`shown_and_sent_row_uuids`) then re-streams the whole fragment on that very
save, showing the still-there row right back. `known` is TRANSITIONAL: every
current reader (`TransitionSync#parse`,
`StepsController#shown_and_sent_row_uuids`, the current JS's own `loadState`)
already prefers `rendered`/`minted` outright whenever either is present, and
the current JS's `saveTransitions` never echoes `known` back — so nothing
about this changes what the current JavaScript sends or how the server reads
it. Delete the key once no tab can still be running the pre-2026-09-19
controller: any release after every open tab has reloaded past this deploy.
Retiring the legacy branch — now the server's `known` fallback AND the view's
`known` key together — is a decision about how long a stale browser tab keeps
working across a deploy, not a cleanup; do not delete either half without
deciding that.

The editor itself now holds only `Step::Doors#extras`, with one exception: a
handoff has no doors at all, so it keeps every transition it has, or there
would be no way to remove one. It renders `rendered` as every uuid it was
shown and an empty `minted` — plus the transitional `known`, the same list as
`rendered`, described above. The JS side (`step_transitions_controller.js`)
mints a new row's uuid straight into `minted` when `addTransition` creates it,
and a REMOVED row's uuid deliberately stays in whichever list already held it
— that is what tells the server "delete this" rather than "someone else
already did." `loadState` also tolerates a hidden field still holding the
legacy single-list shape even though the JS reading it is current — not a
tab that predates the deploy (that tab is running the OLD controller
entirely, which has no such branch), but a fragment Turbo's bfcache restored
from BEFORE this deploy into a page whose module is already the new one:
nothing was minted by this fresh instance, so it is read entirely as
`rendered`.
`Transition.settle_positions` keeps a blank condition sorted after every
conditional one on the same step, since a default edge above a conditional
swallows it.

**The panel submits the whole step on every change, which is the trap here.**
One PATCH can carry a renamed `variable_name` *and* a `transitions_json`
snapshot taken before the rename, so saving the step's own conditions and then
writing the snapshot put the stale ones straight back.
`Steps::Question.rewrite_condition_variable` is therefore applied twice from one
public method — by the model callback to the rows, and by `TransitionSync` to
the incoming payload — and the `[old, new]` pair is captured in
`StepsController#update` **before** anything reloads `@step` and clears its
saved-change tracking. The same save re-streams the Connections fragment so the
editor's snapshot is rebuilt rather than left naming the old identifier. Which
fragment a save streams is decided in one place (`connections_or_doors_stream`):
a rename gets the whole `dom_id(step, :connections)`; so does a save that moved
a transition between doors and extras **in either direction** (a row the editor
was showing became a door, or a door stopped being claimed and became an extra
the editor has never heard of); otherwise a save that touched `answer_type`,
`options` or `transitions_json` gets the doors list alone. One stream per
target, never both. That decision reads the payload's shape through its own
method, `StepsController#shown_and_sent_row_uuids` — a SECOND, independent
reader of `rendered`/`minted`/`known`, kept apart from `TransitionSync#parse`
because it has to answer even when no sync ran at all (no `transitions_json`
submitted, say). Anyone changing what the payload's keys mean has two readers
to update, not one.

**`Steps::TransitionsController`** (`app/controllers/steps/transitions_controller.rb`,
routed `resources :transitions, only: %i[create update destroy], controller:
"steps/transitions"` nested under steps — it is not a `Workflows::` controller)
acts on a single connection from a door row: `create` goes through
`GrowStep.connect`, which retargets the door's own edge if that condition
already has one rather than adding a second the runner could never reach;
`update` retargets one edge by id (what "Change" on a wired door sends); and
`destroy` removes one. Every one of them re-renders the
whole Connections section, not just the row: the editor beside the doors holds a
snapshot, and one still listing a removed connection would save it back on its
next autosave. A refusal is streamed to **both** `#flash` and the dialog's own
error element, because `showModal()` puts the dialog in the browser's top layer,
where a fixed-position `#flash` renders behind it whatever its z-index — the
author would see a dialog that did nothing. A stream aimed at a target that is
not on the page is a no-op, so it need not know which asked. Note
`turbo_stream.update(target, plain_string)` marks the string `html_safe` without
escaping it, so that message is escaped by hand. `create` and `update` also
rescue `ActiveRecord::RecordNotFound` — `target_step_id` (or, for `update`,
the edge id) naming a step or connection that is no longer there, deleted by
this author or a collaborator since the dialog's candidate list was rendered,
or never in this workflow at all — through the same refusal path, with the
candidate list itself (`steps/_target_picker_options`, its own partial so it
can be replaced without closing the `<dialog>` around it) re-streamed when the
stale thing was a target step. `steps/_target_picker` renders **outside**
`:connections`, so only this controller ever re-renders it; its candidate
list otherwise stays honest through the browser's own check
(`step_target_picker_controller#markGoneOptions`, comparing against the
builder's live rows every time the dialog opens, which is what actually keeps
a deleted OTHER step off the list before anyone tries to pick it).

**Which row is selected is decided in the browser**, by
`builder_controller#syncSelectedRow`, from whichever step panel is open, after
every stream render and every panel frame load. Never pass a `selected_step:`
local to the list or row partials: the builder subscribes to its own Action
Cable channel, so a server-painted selection is immediately overwritten by the
same editor's own broadcast of the same subtree.

**Deleting a step answers the way a grow does.** `StepsController#destroy`
replaces the **whole** step list — ordinals shift, and every row that pointed
at the deleted step loses its target and gets its stub back — and separately
streams each parent's own `dom_id(parent, :connections)` fragment; a stream
aimed at a target not on the page is a no-op, so this does not need to know
whether that parent's panel is even open. It also closes a panel left open on
the deleted step **itself**, in the browser: that panel's autosave form
targets `_top`, so its next PATCH would 404 the WHOLE page rather than answer
inside the frame, and `destroy`'s own response only clears the panel when
deleting the step emptied the entire list (`destroy_streams`'
`steps.empty?` branch). `syncSelectedRow` — already the one place that reruns
after every stream capable of replacing the list, to decide which row reads
as selected — closes the panel instead whenever the open step's own row is
gone, which covers both this author's delete and a collaborator's.

**The grow protocol is four data attributes.** A trigger carries
`data-grow-from` (the parent step id), `data-grow-label`, `data-grow-condition`
and `data-grow-context` (what the picker says it is growing from);
`step_list_controller` reads them from a row's stub (`#growFromDoor`) or, for
the panel's own "New step" buttons, from a document-level click handler, and
copies them into the type picker's hidden fields. There is one type picker, and
its door fields are written **when it opens, never when it closes** — choosing a
type closes the picker before the form submits, so clearing on close sent the
grow with no parent. It floats beside whatever was pressed (`position: fixed`,
escaping the list's `overflow-y` clipping) because anchored to the bottom prompt
it opened ~650px from a stub on row 1 of a long list; it is measured with
`offsetWidth`/`offsetHeight`, not `getBoundingClientRect`, which reads a
scaled-down size during the `@starting-style` entrance and threw the clamp off
by that margin. A fixed menu does not move with its row, so scrolling the list
or resizing the window closes it. The bottom prompt keeps the plain anchored
menu.

**At ≤640px with a panel open, `.builder__list` is `visibility: hidden` with
zeroed flex/width, never `display: none`.** The type picker above is rendered
INSIDE that list and reached from outside it too — the panel's own "New step"
buttons, picked up by `step_list_controller`'s document-level click handler —
so a `display: none` ancestor would drop the picker from the render tree
along with everything else, leaving those buttons open a menu that sits at
0×0 with no way to reach it. `visibility` takes the list out of the
accessibility tree and tab order the same way `display: none` would, and the
floating picker overrides it back to `visible` on itself (a descendant's own
value always wins over an inherited one). `test/system/narrow_viewport_test.rb`
guards this.

**No `<form>` inside the panel's autosave form** — nested forms are invalid HTML
and the parser drops the inner one — so each door action avoids one its own way:
"New step" is `<button type="button">` handing off to the type picker, "Remove"
is a `link_to` with `data-turbo-method`, and the target-picker dialog (which
does hold a real form) is rendered **outside** the autosave form, after its
`end`.

**A stale second panel can no longer resurrect a connection someone else
deleted — the `rendered`/`minted` split above closed that 2026-09-19.** What
is left is a narrower, accepted residual: a row minted AND saved in panel B,
then deleted in panel A while B stays open, is still `minted` to B — B never
re-reads it as merely `rendered` until its own Connections fragment is
re-rendered whole. That list is not exhaustive, but includes: a heal (see
above), a rename, a door-shape change, a SubFlow `sub_flow_returns` toggle,
B's OWN tab issuing `StepsController#destroy` for a DIFFERENT step B's open
step connects to (`destroy_streams` answers the request that deleted it — it
is never broadcast to another tab's panel, only rendered into the response
the deleting tab itself receives — and in exactly this case the row could not
have resurrected anyway: `sync_row` only ever DELETES, never recreates, a row
whose target no longer resolves to a real step), or reopening the panel — so
short of one of those, B's own next save re-creates
it exactly as it always could. It needs two PANELS open on the same step's
custom connections at once, not two people — the browser check that verified
this used one editor in two tabs; a tombstone table of deleted
uuids, pruned by a job, would close this case too but was rejected as more
machinery than the risk earns. The other limit this section used to name
alongside it — an option value containing an apostrophe or a backslash never
matching at runtime, because the door condition's escaping and
`ConditionEvaluator`'s reading of it disagreed — was closed the same day: see
the two-readings note above (`Step::Doors#operator_match?` and
`ConditionEvaluator#parse`'s `:value`/`:literal_value`).

**Mode:** `data-builder-mode-value="view|edit"` on the builder container. CSS hides drag handles, add/delete buttons, and edit-only elements in view mode. View mode is a preview: `builder_controller#loadPanel` asks for `readonly=1`, and `StepsController#panel_edit` and `Workflows::SettingsController#show` render the readonly branch for that or for a viewer who may not edit. Nothing in view mode saves.

**Inline Validation + Health Panel:**
- `step_warnings_controller.js` fetches `/workflows/:id/health.json` asynchronously (debounced 500ms) after every autosave or Turbo Stream update
- Warning icons appear inline on step rows with issue counts; clicking opens a popover with issue details and Fix buttons
- Toolbar shows aggregate issue count next to step count; clicking opens the Health panel in the slide-in panel
- Health panel (`_health_panel.html.erb`) shows categorized Errors/Warnings/Passing sections with clickable step links and Fix buttons
- Fix buttons (`connect_next`, `add_resolve_after`) are deterministic, additive autocorrects that respond with Turbo Streams to update both the step list and health panel. A step with more than one door gets **no** Fix for `:no_outgoing_transitions`: both fixes write a blank-condition edge, which on a Yes/No Question catches every answer, so one click let a workflow ship with nobody having looked at No. That issue reads "No answers lead anywhere yet" and opens the step's panel instead
- Import handoff: imports with issues redirect to `?health=true` which auto-opens the health panel on builder connect
- Health fetch is separate from autosave because autosave responds with Turbo Streams (HTML), not JSON

## Controller Architecture

`WorkflowsController` handles CRUD only (index, show, new, create, edit, update, destroy). All other workflow actions are extracted into namespace controllers under `Workflows::`:

- `Workflows::BaseController` — shared `set_workflow`, `eager_load_steps`, `preload_subflow_targets`, and authorization filters. All namespace controllers inherit from it.
- `Workflows::PreviewsController` — step preview with variable interpolation
- `Workflows::VariablesController` — JSON workflow variables endpoint
- `Workflows::FlowDiagramsController` — BFS flow diagram panel
- `Workflows::SettingsController` — workflow metadata panel
- `Workflows::VersionsController` — version history
- `Workflows::HealthsController` — health validation panel (HTML for builder panel, JSON for async fetch). Overrides `eager_load_steps` to skip rich text preloading
- `Workflows::HealthFixesController` — deterministic autocorrect actions (`connect_next`, `add_resolve_after`). Responds with Turbo Streams to refresh both step list and health panel
- `Workflows::ExecutionsController` — start landing page (`new`) + scenario creation (`create`)
- Plus existing: `Exports`, `Imports`, `Shares`, `Publishings`, `Taggings`, `Pins`

One controller is nested under steps rather than workflows: `Steps::TransitionsController`
(`create`/`update`/`destroy`), which acts on one connection from a door row in
the step panel. Builder UI § Growing a workflow says what it answers with and
why a refusal has to render inside the dialog.

**Admin area.** Every `Admin::` controller inherits `Admin::BaseController`, which
overrides `resolve_layout` to `"admin"` — a nested layout adding the section
sidebar inside the application layout (`content_for :content`). `/admin` is the
**Overview**: only what waits on an administrator, from `Admin::Attention`, which
gathers four model questions — `User.awaiting_groups` (Regular/Editor, not
deactivated, no group, so they see only Global workflows),
`Workflow.published_without_audience` (published and in no group, listed newest
first and linking to the admin-only `/workflows?audience=none`), `SmtpSetting.unconfigured?`
(production only, where no relay means Rails' default of SMTP to localhost:25)
and `JobHealth`. It is built once per request and feeds the sidebar's count too,
so the two cannot disagree; the count is kinds of problem, not records.
**`JobHealth` reads Solid Queue's own tables** (failed executions; recurring
tasks with no run in 26 hours, or a run nothing picked up) because both
inferences from app data false-alarm: a run's clock stops while its parent waits
on a live sub-flow, and an unused instance writes no rollup days. The stalled
check relies on Solid Queue keeping finished jobs for at least a day and switches
itself off if that is shortened. They are kept 7 days (`config/application.rb`), so a
stalled job's last run is still on record: Solid Queue's per-run records of nightly jobs
are deleted with the job, so there is nothing else to read. `JobHealth.worker_down?`
reads the newest `solid_queue_processes` heartbeat against Solid Queue's 5-minute alive
threshold — any fresh process counts, so rows a restart left behind can't hide a live
one — and the Overview counts a down worker as its own kind of problem.
**Data Health lists what `JobHealth` found**, in its Background Jobs section
(`admin/data_health/_background_jobs`, fed the request's `Admin::Attention`):
- failed jobs, newest `JobHealth::LISTED_FAILURES` first, each with its error and
  Retry and Discard. Those are `Admin::FailedJobs::RetriesController` and
  `Admin::FailedJobsController`, calling Solid Queue's own `FailedExecution#retry`
  and `Execution#discard` — a discard deletes the job, not only its failure;
- stalled tasks, each with its schedule and last finished run;
- whether the worker is running, from its heartbeat.

The server notes' "When nightly jobs stall" steps are: check heartbeats, then
`bin/rails restart` (Puma's tmp_restart plugin restarts Puma, and its Solid Queue plugin
restarts the worker), then a container restart the way the platform does it.

Solid Queue runs jobs only in production, so no controller test, system test or dev
browser ever shows a failed-job row; `test/views/admin_background_jobs_partial_test.rb`
renders them from hand-built queue rows. A hand-built job needs real serialized
`arguments` to be retried, and must lose the `ReadyExecution` its `after_create`
made. There is no admin Workflows section: `/workflows`
already gives an admin every workflow and delete.
**Who sees a workflow is its groups, and nothing else.** `Group.reachable_ids_for(user)`
— their groups, those groups' subgroups, and **Global** — is the one input to both
`Workflow.visible_to` and `WorkflowAuthorization`; `test/models/workflow_audience_test.rb`
holds the query and the per-record check together. Global is the root group everyone
signed in sees (`Group::GLOBAL_NAME`). It replaced Uncategorized
(`db/migrate/20260910120000`), which auto-filing filled and almost nobody could see,
and the Public flag (`is_public` is an ignored column now). It is looked up and
never created on read, and it refuses rename, move, delete, subgroups, members
and "Only administrators add people".
The safeguards against someone forgetting to choose ship together and must stay
together:
- new workflows start in no group;
- `WorkflowPublisher` refuses one, and `WorkflowSetPublisher` names every member still waiting;
- the health panel warns first (`:no_audience`);
- the Overview lists published ones;
- an import naming Uncategorized arrives without it, with a `retired_group` warning.

A published workflow in no group is seen by admins and its owner only. Editors may
edit Global workflows another editor owns (what Public allowed). A non-admin's save
can add or remove only groups they reach (`Group.assignable_ids_for`).
`Workflow#replace_groups!` is a diff — the Details panel autosaves every field at
once, and recreating the rows wiped the folder filed on each. The `/workflows`
sidebar lists the top-most groups a person reaches, and a workflow in none of its
group's folders is **Unfiled**.
**People choose their own groups, unless an administrator keeps one.** A Regular or
Editor account in no group (`User#awaiting_groups?`, the one-record form of the
Overview's scope) is sent from the dashboard — and only the dashboard — to
`/welcome`, which `GroupOnboarding` owns together with the dashboard notice and a
session-long Skip. `/profile/edit` has My groups for later. Both write through
`User#join_groups!` / `#leave_group!`, which refuse anything outside
`Group.self_joinable_ids`: not Global, not `admins_add_members`, and **not any group
above or below one that is** — membership covers subgroups, so joining the parent
of a managed group would reach it, and a group that could not be rejoined must not
be left. The rule is enforced on write; hiding a group in the picker is not the
guard. `user_groups.self_joined` records where a membership came from, never
whether anyone reviewed it, so `User#replace_groups!` (both admin writers) is a
diff: wiping and recreating erased every mark on each admin save. Locking a group
removes nobody. Self-join does not touch the workflow-audience safeguards above —
it changes who is in a group, not which group a workflow is in.
**Users** are a table plus a page per user (`/admin/users/:id`). The table row is
email (linking out of its Turbo Frame with `data-turbo-frame="_top"`), the inline
role select, groups and joined; everything else — groups, password reset,
deactivation, workflows owned, last active (newest run, since `:trackable` is
off) — is on the user page. `update_groups`/`deactivate`/`reactivate` return
there; `update_role` uses `redirect_back_or_to` because both surfaces call it.
Group paths come from `Group.tree_nodes` / `Group.paths_by_id` (one query for the
whole tree) and every group picker is `shared/_group_picker`; `Group#full_path`
queries ancestors per call and must not be used in a loop. Every Users dialog is
a native `<dialog>` that closes on `turbo:before-cache` — see UIGUIDE § Dialogs
for why, and for the `visible: :all` trap in testing it.

**Groups** are a tree plus a page per group (`/admin/groups/:id`). The tree renders
flat, depth-first rows from `Group.tree_nodes`, each carrying its ancestor ids, and
`group_tree_controller.js` shows and hides them by set lookup:
- it starts collapsed to the roots;
- a filter matches any part of a path and opens the groups above a match;
- nothing is remembered.

Row counts come from `Group.member_counts` (direct) and
`Group.workflow_counts_including_subgroups`, each equal to what its link lists, and
tested that way (`test/models/group_counts_test.rb`).

A group's page is its department hub:
- subgroups by name;
- direct members, through `Admin::MembershipsController`: a search in a turbo-frame
  that stays open after Add, and Remove with no confirm;
- folders: add by name, rename in place, drag, delete. There are no folder pages
  any more;
- a workflow count linking to `/workflows?group_id=`;
- a delete refused while subgroups or workflows remain, with the page saying so
  instead of offering the button.

Members and folders answer with Turbo Streams that replace their card and update
`#flash` in the application layout. Global's page has only Folders. Groups sort by
name ignoring case everywhere, and have no position column.

**Groups nest up to `Group::MAX_DEPTH` (5) levels**, and the limit is enforced where
it is offered:
- a move checks the whole subtree it carries, not just the moved group (moving a group
  with two levels of subgroups under a fourth-level group used to save it at level 7);
- the check runs only when a group is created or moved, so an already-too-deep group
  can still be renamed;
- the Parent select offers only parents that can take the group and everything under
  it, and always keeps its current parent;
- the group page hides Add Subgroup at the limit and says so.

The member search answers as you type (`debounced-submit`). Its field sits outside the
results frame it fills, because inside it every answer replaced the input being typed in.

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

## Real-Time & Collaboration

- WorkflowChannel (Action Cable) — presence (who's editing), live updates
- In-memory cable in dev; Redis or Solid Cable in production
- Optimistic locking prevents save conflicts

## Workflow Engine

All workflows are graphs. There is no separate "linear mode" — a sequential flow is just a graph where each step has one transition to the next.

**Key services:**
- `StepResolver` — graph traversal engine. Evaluates transitions in position order, handles conditional branching (via `ConditionEvaluator`), simple value matching for Question answers, SubFlow markers, and jump evaluation (`check_jumps`).
- `GrowStep` — the builder's own writer: one step plus the edge that reaches it, in one transaction, inserted after its parent. Never called from import, and deliberately not part of `StepBuilder`. See **Builder UI § Growing a workflow**, which also covers `Step::Doors` (a model, `app/models/step/doors.rb`, not a service) and `TransitionSync`.
- `TransitionSync` — saves the step panel's connection editor by uuid: an existing row named in `rows` is updated, a missing row is created only when this editor minted it rather than merely rendered it, and `(rendered + minted) - rows` is deleted — so a stale second panel can no longer resurrect a connection someone else deleted (the pre-2026-09-19 `{known, rows}` shape is still honoured, for a browser mid-deploy; the transitional editor field carries `known` too, so a browser mid-deploy can still remove a connection, not just add or edit one — see **Builder UI § Growing a workflow**). It replaced a `destroy_all`-and-rebuild that deleted edges written while the panel was open.
- `StepBuilder` — creates AR steps from hash data. Auto-creates sequential transitions when no explicit transitions provided. Validates at least one Resolve step exists. Also provides `StepBuilder.normalize` (class method), its own helper, which `WorkflowImporter` borrows.
- `ScenarioStepProcessor` — extracted step-processing logic for Scenario. Calls public methods on Scenario (`advance_to_next_step`, `resolve_at_current_step`, `record_completion`).
- `GraphValidator` — graph validation: reachability from start_step, terminal nodes must be Resolve steps, and **escapability** — from every step reachable from the start, some path must reach a terminal Resolve (`:no_path_to_resolve`). It does **not** reject cycles: a retry loop is a normal call-centre shape, and what is refused is a loop with no way out. This replaced an acyclic check; for an acyclic graph the rule asserts nothing new, since every node in a finite DAG already reaches a terminal and terminals must be Resolve steps.
- `SubflowValidator` — sub-flow graph rules. Refuses an **all-returning** cycle (a handoff leaves no stack frame, so only a returning cycle nests), caps returning nesting at `MAX_DEPTH` (10), reports a target that no longer exists, and refuses a set of workflows from which no Resolve is reachable (`:no_resolve_across_workflows` — seeded from workflows that reach a Resolve unaided, spread backward along handoff edges, and skipped entirely when the graph has no handoff, where `GraphValidator` already answers it). `SAVE_BLOCKING_CODES` names which of these block an ordinary save.
- `WorkflowSetPublisher` — publishes a workflow together with every draft it transitively depends on, in one all-or-nothing transaction, so workflows that reference each other can go live at all. `closure_for(root)` previews the set without writing. Checks `can_be_edited_by?` across the **whole** closure, not just the root — publishing your own workflow must not publish someone else's draft that yours happens to reference.
- `StrictImportValidator` — validates a strict-dialect file without writing: envelope, structure, graph (same `GraphValidator` publish runs), semantics (condition syntax, undefined variables, unmatched option values), and external references (groups via `WorkflowPlacement`, sub-flow targets scoped to `Workflow.visible_to`). Returns a `Report` of errors and warnings; `WorkflowImporter` takes a valid one via `strict_report:` and only writes. The option-value check reads a condition through `ConditionEvaluator#parse` rather than its own regex, matching either of the value's two readings against the question's option values — coerced to strings, so a bare JSON number in an option does not false-positive against a quoted condition — and a genuinely numeric-looking mismatch (`plan == '9'` against `["3", "4"]`) still warns. An unquoted `plan == 9` never reaches this check: `#supported_condition?` refuses it earlier as `:invalid_condition_syntax`, since `==`/`!=` require a quoted value.
- `ConditionEvaluator` — the grammar every reader of a condition shares: a string value is delimited by `'` or by `"`, the SAME one at both ends, and inside it a backslash escapes the next character. `#evaluate` and `#parse` read through one private tokenizer (`#string_comparison`); `#valid?` and `#complete?` never call it — they derive their patterns from the same string-value fragment, plus `LEGACY_STRING_VALUE`, the pre-2026-09-19 value pattern verbatim (its delimiters need NOT match). That keeps both a strict SUPERSET of what they accepted before this branch, not a narrower grammar: mismatched delimiters (`'yes"`) and a value ending in a bare backslash (`'C:\'`) are still accepted by both, exactly as they always were — a base-vs-current diff found zero conditions that were accepted before and are refused now by either. The WIDENING is visible at `#complete?` only: only a value containing a quote character — its own delimiter escaped, or the other delimiter unescaped, e.g. `'Say "OK"'` — is newly accepted there. `#valid?` accepts NOTHING new: its pattern is anchored at the start but not the end, so a mere prefix match is enough, and the pre-2026-09-19 pattern already supplied a quote-delimited prefix for any text with a quote character anywhere later in it — `light == 'Say "OK"'` already satisfied `#valid?` before this branch by matching only as far as `'Say "`, well short of the whole string, which is exactly why `#complete?` (anchored at both ends) needed the fix and `#valid?` never did. A bare backslash was never what the old pattern excluded either way, so it changes nothing about what `#complete?`/`#valid?` accept, only what `#evaluate`/`#parse` understand such a value to mean. `#complete?` is the one that matters in practice — it is what `StrictImportValidator#supported_condition?` and the Markdown parser ask, to refuse a compound condition and to tell a condition from a label respectively — and narrowing it below what it used to accept would make an exportable workflow un-importable, or misread an existing Markdown transition as a label. `#valid?` itself has no caller in `app/`; only `#complete?` is. `#parse` returns `:value` (unescaped) and `:literal_value` (the text between the delimiters exactly as written, backslashes kept) — both readings, never nil whenever `#parse` returns a hash at all: its own legacy fallback (splitting on the first supported operator, tried longest first, that appears ANYWHERE in the text — not the leftmost one, so `x == 'a>=b'` splits on `>=` — and stripping every quote character) sets both to the same stripped string. Both branches also return `:is_numeric`, which nothing in `app/` reads. Two DIFFERENT readings arise because a condition written before 2026-09-19 escaped a quote but never a backslash (`Step::Doors#condition_for` and the panel's writer both only ever did that), so a stored `path == 'C:\temp'` means a literal backslash, not an escape. `#evaluate`'s `==`/`!=` match an answer equal to EITHER reading, and every other reader that asks "does this condition mean this value" — `Step::Doors#operator_match?`, `StrictImportValidator#check_option_value`, the panel's `conditionsMatch` — has to check both, or re-create the bug this closed. When one of those checks fails, what gets reported is quoted AS WRITTEN, not unescaped: `StrictImportValidator#check_option_value`'s `unmatched_option_value` warning and `Step::Doors#unmatched_extras` (a separate Doors method from `#operator_match?`, feeding the health panel) both report `:literal_value`, so the author sees the backslash they actually typed. The cost: where the two readings differ (the value contains a backslash), `!=` is stricter exactly where `==` is looser — an answer matching either reading satisfies `==`, so it must fail to match BOTH before `!=` is true. The tokenizer only fires when the WHOLE condition is one well-formed string comparison; anything else — mismatched delimiters, an unquoted `x == 5`, trailing text — falls through to the reader this class has always had, unchanged: a live workflow must not change routing when the parser gets better. Verified by diffing old vs. new `#evaluate` over ~12.9M generated cases — every disagreement fell into three named, deliberate families: a value containing a quote (the fix), one containing a backslash (the two-readings rule above), and one containing the substring `!=` (the old reader split on it and matched every answer regardless; now it compares for real — nobody could have been relying on an always-true branch). Writers (`Step::Doors#condition_for`, the panel's `escapeQuotes`) escape a backslash before the delimiter — in that order, whether as one `gsub` over both characters or two chained replacements — so a value round-trips whatever QUOTE OR BACKSLASH it contains. Surrounding whitespace never does: both the tokenizer and the legacy reader strip the extracted value once they read it, while the answer side is compared raw — see "Option labels and values are trimmed on save" above for why that makes trimming an option at the source the only fix.
- `ImportSchemaGenerator` / `ImportPromptGenerator` — the published JSON Schema and the agent prompt, both generated from the models so neither can drift from what the app accepts.
- `WorkflowHealthCheck` — aggregates GraphValidator + SubflowValidator + step-level checks into a per-step issue map. Returns `Data.define` Result with issues keyed by step UUID, severity levels, fixable flags, and summary counts. Used by both the health panel (HTML) and async JS fetch (JSON). Two codes read `Step::Doors`: `:missing_expected_door` (an answer with no step of its own — "“No” has no step yet", suppressed by a blank-condition edge, which catches it) and `:unmatched_option_value` (a connection checking for a value the step no longer offers). Both are warnings and both are in `NON_BLOCKING_CODES`; neither is in `READINESS_CODES`, which asks whether a step's *content* is filled in, and these are routing findings. `:no_outgoing_transitions` stays an error but loses its Fix on a multi-door step (see Builder UI).
- `WorkflowPublisher` — publishes workflow versions with full graph validation. Uses `Workflow#validation_graph_hash`.
- `FlowDiagramService` — BFS layout for the builder's flow diagram panel.

**Constraints enforced:**
- Transitions must connect steps within the same workflow (cross-workflow via SubFlow only)
- Every workflow must have at least one Resolve step
- All terminal nodes must be Resolve steps (on publish)
- Every step must be able to reach a Resolve. Cycles are allowed; unescapable ones are not
- Step UUIDs are immutable after creation
- Optimistic locking on both Workflow and Step (`lock_version`)

## Home Page

`/` is two pages, and both are about the viewer's own work and nothing else.

A Regular user gets the **CSR home** (`dashboard/csr`, `Dashboard::DataLoader`):
a call to pick back up, what their teams feature for them, their pins, and the
workflows they recently started.
Browsing and pinning are `/play`.
- **No workflow title on it is a link.** A Regular user has no page for a
  workflow, since `WorkflowsController` and `ScenariosController` are closed to
  them, and `POST /play/:id` starts a live call, so Run buttons are the only way
  in. From `263717c8` (2026-04-07) until 2026-09-13 every title, "Manage pins",
  "View all" and Recent Activity row sent a CSR to `/play` with a permission
  error. `test/integration/csr_home_links_test.rb` follows every link on the page
  as a Regular user.
- **Its lists count calls the CSR started** (`Scenario.origins`), because a
  sub-flow or handoff frame carries the same user and purpose as its call. Each
  Recently Run row says how the latest call ended, read from `CallStatistics`,
  in Analytics' words.
- **Resume is one line:** the call with the latest activity inside
  `Dashboard::DataLoader::RESUME_WINDOW` (60 minutes) that still has an
  unfinished frame. Closing the tab is how calls usually end, so most unfinished
  runs are over. It opens the unfinished frame with the latest activity, and
  "Run a Flow" stays the page's filled button.
- **Pins are personal, and only Regular users get a pin toggle** (on `/play` and on
  home), because only the CSR home reads pins. `workflows/pins/_toggle` is the
  only toggle, and `Workflows::PinsController` replaces every copy of it.
- **"From your team" comes before pins.** It shows what the CSR's own groups (direct
  membership, not sub-teams or parents) and Global feature for them.
  - **Headings:** one per team in name order, with Global last as "For everyone". A
    team whose name another of the CSR's teams shares is headed by its path instead
    ("Support / Phone"), since names are unique only under one parent.
  - **What each team shows:** its kit, the first 8 its members can see. The kit is
    cut before anything is left out, so a pin never lets a ninth in. After that, a
    workflow shows once and a pinned one isn't repeated.
  - **Empty and day-one states:** with nothing featured it renders only an empty
    `#team-workflows-section` wrapper, which a pin change replaces. When it has rows
    and the CSR has no pins, "Your fast path" is one line.
  - **Where it's read:** `Dashboard::DataLoader#team_sections`. Every team's
    visibility comes from one batch (`Group.member_visible_workflow_ids`, held to
    `Workflow.visible_to_members_of` by `test/models/workflow_audience_test.rb`), so
    the queries don't grow with the CSR's teams. Pinned and featured rows share
    `dashboard/_launcher_row` and `#run_stats`.

**Featured workflows and the team page.** A group's standard kit
(`GroupFeaturedWorkflow`), curated on its **team page** (`/teams/:id`). "Team page"
means a group's page outside the admin area, and the data is still a group.
- **Who curates:** `TeamCuration` answers for the top-bar "Teams" link, `/teams`, every
  team page and every change. An administrator curates every group, Global included;
  a manager curates their groups and sub-teams (`GroupManager.team_group_ids_for`, the
  reach Analytics uses) and never Global.
- **What it may feature:** only what its members can already see
  (`Workflow.visible_to_members_of`: published, and filed in the group, a subgroup, or
  Global). Featuring never changes who can see a workflow.
- **The cap:** members get at most 8 per group, the first 8 they can see, in the
  curator's order (`GroupFeaturedWorkflow.kit`). A row they can't see holds no place.
  It stays on the team page, marked, until it's removed or visible again, and then it
  returns in its place. That can push a visible row past the 8th. Members don't get it
  on home but can still run it from `/play`, so the team page says "Past the first 8 ·
  not on members' home pages" in plain text rather than with the pill. Adding a ninth
  visible row is refused.
- **The page:** every change answers with a Turbo Stream that replaces
  `#team-featured`. Feature and Remove also report through `#flash`; Move and a drag
  re-render the card in place, so Move up and Move down follow the new order and Move
  keeps focus on the row that moved. A drag that doesn't save (an error such as the
  401 a lost session answers with, no answer, or a redirect such as lost access, which
  the fetch doesn't follow) puts the rows back and says so through `#flash`,
  using `app/javascript/services/flash.js`. Drag reordering uses `sortable-list`, the same
  controller as the admin group page's folders, which renders a stream only when the
  endpoint sends one (the folders endpoint answers an empty 200).

An Editor or Admin gets **home**:
- a hero card for the workflow they were last in;
- "Waiting on you", one row per kind of problem, naming the workflows;
- their other recent workflows;
- for an admin, one strip from `Admin::Attention`.

Org-wide stats and a feed of other people's runs used to live here. Analytics does
the first properly, and the feed's links 404'd for anyone but the run's owner.

- **Last edited is `Workflow.recently_edited`,** the later of the workflow row and
  its newest step, because a step edit never touches the workflow. A
  transition-only change counts as neither, deliberately: `touch:` on `Transition`
  would bump the step's `lock_version` under the step panel's autosave.
- **"Can't publish" is `WorkflowHealthCheck::PUBLISH_BLOCKING_CODES`,** an
  allowlist, not a severity: `no_audience` and the sub-flow codes are warnings, and
  each blocks a publish. Every code the check can emit is classified, and a test
  scans the three emitters. Home runs the check once, for a draft hero only.
- **Every "your" link lands on `/workflows?owner=me`.** An admin's Drafts tab is
  org-wide, so a personal count linked there led to a list of other people's work.
- **Returning to either dashboard must render once:** no entrance animation, no
  Turbo preview, nothing loaded after render. See UIGUIDE § Motion.

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

**Auto-advance has one source of truth:** `RunnerHelper#runner_auto_advances?`.
It drives both the Stimulus value on the shell and whether Continue renders in
the partial. Those must agree — when they didn't, a question with options and an
unexpected `answer_type` rendered radio cards with no way to submit.

## Navigation & Search

- `NavController` (Rails) — `search_data`, the only nav endpoint. There was a
  `menu` action serving a lazy Turbo Frame for a dropdown hung off the wordmark;
  it and its route, views and Stimulus controller were deleted 2026-09-09
- `nav_search_controller.js` — Cmd+K fuzzy search (Fuse.js) across workflows, respects user permissions
- **Two-zone header: brand + destinations left, search + chrome right.** Every
  destination is a labelled link — Workflows, Play, Teams, Analytics, Admin — not a menu. The
  wordmark used to hold the centre column of a `1fr auto 1fr` grid, which is
  what created the spare slot beside it that a chevron menu filled, and which
  pinned the destinations to the right edge next to the theme toggle and avatar,
  where a place reads as a setting. `/admin` was reachable **only** through that
  chevron, which is why eight admin pages carried a "Back to Dashboard" control;
  six went when the bar gained the destination, and the rest when admin got its
  own section sidebar (`layouts/admin`, `AdminHelper::ADMIN_SECTIONS`)
- `NavHelper` owns which controller lights which item (`NAV_SECTIONS`,
  `nav_section`, `nav_current`). It is section-level: `scenarios`, `steps` and
  `workflow_versions` light Workflows, every `admin/*` page lights Admin, and
  `analytics` and every `analytics/*` page (the Agents and Runs drill-downs)
  light Analytics. Teams lights on `teams` and every `teams/*` page. Those first three used to light nothing — you could be
  mid-scenario in the builder with an entirely inert bar. **Add a controller to
  the map when you add a surface**; absence is the deliberate answer for pages
  reached from inside a section (profiles, tags, folders), never a default
- The current item is `--color-primary-text` + a 2px rule, matching `.tab-bar`.
  It must stay a different *channel* from hover: the old treatment moved active
  from `--color-ink-subtle` to `--color-ink`, which is exactly what hover did,
  so "where am I" and "where is my mouse" were indistinguishable
- **The player layout is for runs, not for the Player as a namespace.**
  `PlayerController#resolve_layout` (overriding `ApplicationController`'s) puts
  `index` on the application layout and everything else on `player`. The index is
  a browse page — heading, filter, list rows — and it is also the only rendering
  action here that always requires a session, since `step`/`show`/`show_shared`
  stay open for anonymous share links; the same line is drawn twice. So the
  chrome falling away means *you have entered a run*, rather than being an
  artifact of where a `layout` call sat. Until 2026-09-09 `layout "player"`
  covered the whole controller, which made `:play` unhighlightable and left a
  regular user — whose only other destination is the dashboard — with a top bar
  on exactly one page. Note a class-level `layout "x", except: :index` does **not**
  fall back to the parent's `layout :resolve_layout`; the excluded action renders
  with no layout at all, which is why this is a method override

## Other Highlights

- Rich text: Action Text + Lexxy (Lexical editor)
- Global search: Fuse.js (Cmd+K via `nav_search_controller.js`)
- Drag-and-drop: SortableJS
- No multi-tenancy (single install/org), but strong group-based access
- Background jobs: Solid Queue (in-process via Puma plugin, `config/recurring.yml` for schedules)
- **Retention only ever collected runs people finished, and that is now fixed in three places.** Both cleanup scopes need `terminal` **and** a `completed_at`, so anything that ended without both was immortal. (1) Nothing moved a run out of `active`/`awaiting_subflow` — and agents close the tab rather than clicking Cancel, so the common ending leaked (52% of rows in a dev DB). `Scenario.sweep_idle_runs` settles a run idle past `SCENARIO_IDLE_TIMEOUT_HOURS` (default 24) as `status: "timeout"`, `outcome: "abandoned"`, via `SweepIdleScenariosJob` at **02:00 — deliberately before cleanup at 03:00**, since a run settled after the night's cleanup waits another day. (2) Both writers of `status = 'error'` set the status and nothing else, so errored runs had a NULL `completed_at` and `NULL < date` is never true; they now `record_completion("error")`. (3) `Scenario#terminal?` compared the enum READER (which returns the label `"timed_out"`) against `TERMINAL_STATUSES` (which holds DB values `"timeout"`), so it was **false** for `timed_out`/`errored` while the SQL scope was correct — Ruby and SQL disagreeing about the same row. Only the two members where label ≠ value were affected, which is why it read correctly for years. **`completed_at` is always the run's real last activity, never `Time.current`** — stamping `now` grants ancient rows a fresh retention window and collapses history onto one timestamp; `record_completion` takes `at:` for this. Run `rake scenarios:sweep_idle DRY_RUN=1` after deploying and read the count **before** the first pass: the backlog is stamped with real times, so anything past its horizon is collectable immediately
- **A run's idle clock is the whole run, never one frame.** `Scenario#run_frames` — seeded from `run_origin`, closed over child/parent **and** handoff links in both directions — is the sixth reader of run topology and the first to enumerate a whole run. `belongs_to :parent_scenario` has no `touch:`, so a parent parked on a *live* sub-flow has a clock that stopped when it parked, and `run_head` returns exactly that parent, because neither it nor `run_origin` descends into an ordinary sub-flow child. Keying on either settles runs an agent is still working. `run_frames` drives both the clock and the settle so the two cannot disagree. Do **not** fix this with `touch: true`: it puts N ancestor writes and N optimistic locks in the runner's hot path per sub-flow step, and still misses handoff chains. `time_out!` is named around the enum's own `timed_out!`, which flips the status and records nothing — the shape of bug (2) above.
- **Trend history is rolled up before the runs are deleted, and which days get rolled is the whole design.** `ScenarioRollupBuilder` writes `scenario_rollups` (workflow x day x purpose x outcome -> count, duration SUM + COUNT) and `scenario_dropoff_rollups` (workflow x day x step_title), via `RollUpScenariosJob` at **02:30 — between the sweep (02:00) and cleanup (03:00)**, an order that is load-bearing on the first night and guarded by `test/integration/recurring_schedule_order_test.rb`. The obvious rule — re-roll every day that still has raw rows — **corrupts history**: cleanup keys on `completed_at` while a rollup keys on `started_at`, so a day's runs are deleted across several nights, and recomputing from the survivors undercounts and then freezes at the wrong number. So a day is rolled only while it is still moving: it has no rollup rows yet (first run, or a missed night), or it falls inside `REFRESH_DAYS`. Writes are **delete-then-insert, not upsert** — a run that settles moves from `"pending"` to its real outcome, and an upsert leaves the stale pending row behind. Durations are a SUM and a COUNT, never an average, so averages compose across days. Drop-off needs its own table because the step is read from `execution_path.last`, which no aggregate of outcomes can reconstruct
- **Analytics has two modes and never stitches them.** Within retention it reads individual runs and every filter works. **"All time"** (`params[:range] == "all"`, administrators only, since a rollup has no agent to limit to a manager's team) reads the rollups instead: it reaches past the horizon but cannot answer per-agent, per-step or time-of-day questions, so those panels render `_rollup_unavailable` rather than an empty table, the run-level filters are hidden rather than shown inert, and CSV export redirects rather than handing over 90 days labelled "all time". A blended view would be exact for recent ranges and quietly partial for older ones — the exact failure the rollups exist to remove. **Every rate divides by finished runs**, and `Scenario::COMPLETED_OUTCOMES` (completed, resolved, escalated, transferred) is what counts as completed — in both modes and on every tab, headline and Workflows and Agents alike. A run still going has not failed to complete, and escalating or handing off are endings a workflow is built to reach. A run with no outcome reads **In progress** (a rollup's `pending` too); the label and bar colour come from `AnalyticsHelper`
- **The analytics headline counts calls; the tables count runs.** A call starts in one workflow and can pass through several — a returning sub-flow is a child scenario, a handoff a new one — so counting scenario rows read two routed calls as "Total Runs 10" and averaged their durations piecewise (fixed 2026-09-12). `CallStatistics` counts origins (neither `parent_scenario_id` nor `handed_off_from_id`) from the page's filtered scope, so every filter means where the call *started*; a call's outcome and finish come from its ending, chosen in SQL as `Scenario#run_ending` chooses it, and `CallStatisticsTest` holds the two to the same answer shape by shape. The headline figures are added up in one grouped query (by ending outcome and starting day), never by loading every call: that took a 90-day page on the load-test replica (496k calls) 6 seconds and 430 MiB a request. Its duration and day SQL is spelled once for SQLite and once for Postgres, and `CallStatisticsTest` holds it to the same figures as `calls`, which lists calls one by one for the pages that show a handful. Every frame records its call in `scenarios.run_origin_id` (NULL on an origin, set in `before_create` from the link it is born with), because SQL cannot walk `run_origin`. The stat cards, outcome breakdown and Calls Over Time read calls; Workflows, Agents, step performance, drop-off and CSV stay per run. **All time counts calls too** — `scenario_rollups` carries `calls_count` and call duration sums on the same grain, keyed by the call's starting workflow and day and its ending outcome — but days rolled before the columns existed hold zero calls and were deliberately not backfilled (re-rolling part-cleaned days is the undercount trap below), so the page says from when calls are counted
- **Analytics is for administrators and the managers of groups, and `AnalyticsScope` decides what each sees.** A CSR manager must not become an administrator to coach their team, so an Admin marks someone as manager of a group on the group page (`group_managers`, deliberately not a flag on `user_groups`, which people join and leave themselves), whatever their role. `AnalyticsScope.new(user)` is the one answer to "whose runs": an administrator every run; a manager runs by members of the managed groups and their sub-teams, read at request time; anyone else none. `AnalyticsController` (now `/analytics`, outside the admin shell, which stays admin-only in every controller), its filter lists, its CSV and the read-only drill-down (`Analytics::AgentsController` for one agent's calls, `Analytics::RunsController` for one call, both through `AnalyticsAccess`) all ask it. Scoping is by who ran it, so a handed-off call stays whole and a manager sees their team's runs on workflows they cannot open. Managers get 7, 30 and 90 days: All time reads rollups, which carry no agent. An out-of-scope agent or run and a nonexistent id get the same redirect. Team membership is what a manager's view rests on, so a CSR must be a member of their team group, and a self-joinable team's manager sees whoever joins it. A manager in no group of their own still counts as awaiting groups — the Overview, the admin sidebar badge, and `/welcome` after every sign-in all flag them the same as anyone else with no group, and they see only Global workflows in Play — so make each manager a member of their own team. The Managers card marks any manager in no group ("In no group"), reading the same `User.awaiting_groups` scope as the Overview so the two cannot disagree
- **A workflow version's RECORD is permanent; only its restorable payload has a limit.** Nothing is ever deleted — `workflows.published_version_id` is a RESTRICT foreign key, and a design that removed rows would have to reason about that on every path. `WorkflowVersion#strip_snapshot!` nulls `steps_snapshot` and stamps `stripped_at`, keeping the number, date, publisher, title and changelog: `metadata_snapshot` is ~265 bytes against ~9.5KB of steps, so the history costs ~3% of the storage. The newest `WORKFLOW_VERSION_RESTORE_LIMIT` (default 10) stay restorable — a **count**, not an age, because a workflow published twice a year is exactly where you have forgotten what changed. Released **on publish**, not nightly: the rule is a count and only a publish can push a version past it, so a scheduled scan would hunt for work `WorkflowPublisher#release_old_snapshots!` already knows about. The existing backlog was closed once by a migration, since a workflow published fifty times and then abandoned is never published again
- **Republishing unchanged content reuses the existing version.** `WorkflowPublisher` compares both `steps_snapshot` and `metadata_snapshot` (a rename with identical steps IS a change) and skips the write when they match. This compounds through `WorkflowSetPublisher`, which publishes a whole dependency closure: a ten-workflow set republished for one change wrote ten versions, nine identical. Unlike releasing a snapshot, skipping the write destroys nothing. `version_number` is display-only, so gaps are harmless — but note two existing tests had to change, because both republished unchanged content and asserted a v2
- **The changelog is written retroactively, from the versions list, by anyone who `can_be_edited_by?`.** Publishing a single workflow is one `button_to` click; a dialog there to capture an optional field is the one people dismiss, which buys the friction and the empty column both. `published_by` is never touched, so authorship of the publish survives someone else annotating it. A released version is still annotatable — the record is the durable artefact. The versions list paginates (`Workflows::VersionsController::PER_PAGE`) because that record now only grows, and the compare dropdowns offer only restorable versions: a diff reads `steps_snapshot` on both sides, and a menu should not list what it cannot do
- **`scenarios.workflow_version_id` records which script the agent followed**, set by a `before_create` on `Scenario` rather than at the four `Scenario.create!` sites — a sub-flow child runs a *different* workflow and must record that workflow's version. It is nil for a simulation of an unpublished draft, which is correct. It does **not** hold a snapshot alive: the link answers *which* version, and that is kept permanently anyway. The column, its index and its FK existed for a long time with nothing writing them (0 of 120 rows), and there was no `belongs_to` either
- Data lifecycle: tiered scenario retention (7-day simulation, 90-day live), batched cleanup via `CleanupScenariosJob` + `CleanupDraftsJob` (daily at 3 AM), admin visibility at `/admin/data_health`, whose "For whoever runs the server" disclosure lists the env vars with their current values, the rake commands, and the schedule read from `config/recurring.yml`. **A draft with steps is never auto-deleted** — both draft-cleanup scopes require the workflow to have none. `orphaned_drafts` also requires the title `"Untitled Workflow"` and 24 hours; `expired_drafts` requires a `draft_expires_at` in the past. Imports carry a nil TTL, so they match neither
- **Uploaded files have two cleanups, and both are needed.**
  - **Deleting a workflow purges the images its steps embed.** Each step's rich text
    is destroyed with callbacks, which purge its `embeds`.
    `Workflow#nullify_start_step` used to `delete_all` them for a foreign key that
    rich text doesn't have, and every image outlived its workflow (fixed 2026-09-13).
  - **Unattached uploads are swept.** Lexxy uploads an image the moment it's
    chosen, so one removed before its step saves, or chosen in an editor closed
    without saving, attaches to nothing. `PurgeUnattachedBlobsJob` (03:30) purges
    those once they are older than `GRACE` (2 days).
  - **Shared images are safe in both:** Active Storage won't destroy a blob that
    still has attachments, and destroying one clears its resized copies
    (`variant_records`). Guarded by `test/models/workflow_image_cleanup_test.rb` and
    `test/jobs/purge_unattached_blobs_job_test.rb`.
- Security: Rack::Attack, Bullet (N+1), Brakeman

## UI Guide
@UIGUIDE.md

## Coding Style
@STYLE.md

## Tools
Playwright MCP (for UI/system testing). Point agent to running app at `http://localhost:3000` (after `bin/dev`). Allows browser control (click, type, snapshot, inspect) — ideal for testing the builder, Scenario simulation, and drag-and-drop.

## Deployment Notes

- Branch: `main`
- Tool: Kamal + Puma + PostgreSQL + Solid Queue (in-process)
- Solid Queue runs inside Puma via `plugin :solid_queue` (no separate container)
- Recurring jobs configured in `config/recurring.yml`: cleanup scenarios + drafts daily at 3 AM, and unattached uploads swept at 3:30
- Retention configurable via ENV: `SCENARIO_RETENTION_SIMULATION_DAYS` (default 7), `SCENARIO_RETENTION_LIVE_DAYS` (default 90), `SCENARIO_IDLE_TIMEOUT_HOURS` (default 24 — the sweep runs nightly, so the real window is this plus up to a day)
- Pre-deploy: RuboCop + full test suite (run locally before deploy)
- The `20260911120000_add_self_join_to_groups` migration makes every existing group self-joinable (`admins_add_members` defaults to `false`), and sign-up is open — right after deploying, an administrator should mark sensitive groups "Only administrators add people" before the feature is announced
- The `20260915120000_backfill_step_defaults` migration writes `resolution_type = 'success'` on Resolve steps and `priority = 'medium'` on Escalate steps that had a blank; it runs unattended and needs no operator step
- The `20260918120000_add_uuid_to_transitions` migration backfills every transition, then adds `NOT NULL` and a unique index, all in one DDL transaction — on PostgreSQL the table is locked for the duration. Seconds for thousands of rows; check `Transition.count` first if the install is large. There is also a cutover hazard: while the previous container is still serving requests against the already-migrated schema, its step-panel autosave deletes a step's transitions and then fails to re-create them (the old code has no uuid to key on, no `NOT NULL` default, and no transaction) — the deletes stay, the re-creates don't. Deploy this migration when nobody is in the builder, or stop the old container before `db:prepare` runs against the new schema
- The `rendered`/`minted` deploy (2026-09-19) has the same shape of cutover window, narrower than it first looks because of the transitional `known` key: a NEW-JavaScript tab's hidden `transitions_json` field holds whatever the server last rendered into it — `known` included — UNTIL `saveTransitions` overwrites it, which only happens when the author actually adds, removes or edits a connection in that panel (`step_transitions_controller.js#connect`/`#refresh` never call `saveTransitions`, so opening the panel and editing some OTHER field never touches it). So a save that never touched connections still carries `known` and an OLD container's `TransitionSync#parse` accepts it and reads it legacy-style, correctly — nothing is refused. Only a save made AFTER the connections editor was touched sends the current shape (`{rendered, minted, rows}`, no `known`), and THAT one an OLD container refuses: `TransitionSync#parse` requires `known` present as an Array or raises `Malformed` ("This step was saved, but its connections were not…") — the step's own fields still save first (`@step.update` runs before `sync_transitions`), so no TRANSITION is written or deleted on that request, but the rest of the PATCH did write. It clears as soon as the cutover completes and every request reaches a new container
