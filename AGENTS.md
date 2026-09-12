# AGENTS.md

This file provides guidance to AI coding agents working with TurboFlows.

## What is TurboFlows?
A straightforward workflow creator for call/chat centers to build, simulate, and manage post-onboarding training + client troubleshooting flows with drag-and-drop simplicity.

- Seven step types: Question, Action, Sub-Flow, Message, Escalate, Resolve, Form
- **A Sub-Flow either returns or hands the run over.** `steps.sub_flow_returns` defaults to `true`, which is the call/return behaviour that has always existed: a child `Scenario` is spawned, its results merge back, and the parent resumes at `resume_node_uuid`. Set it `false` and the step is a **tail call** — the run moves to the target workflow and never comes back, so the step ends this workflow, takes **no transitions**, and needs no Resolve after it. That is why a workflow can now *point* a user at another one instead of dead-ending. Concretely, a handoff differs everywhere the run's shape is read: `Scenario#hand_off!` settles this frame **and every ancestor still waiting on it** (`status: "completed"` + `outcome: "transferred"` — terminality and *how it ended* on separate columns, so reporting can tell a handoff from a completion); the handed-to scenario carries `handed_off_from_id` and **no** `parent_scenario_id`, because nobody is waiting for it; `GraphValidator` accepts it as a legal terminal; `SubflowValidator` exempts it from `MAX_DEPTH` (a tail call leaves no stack frame) **and from cycle detection** — a cycle is refused only when *every* edge in it is a returning call, because `hand_off!` settles the whole waiting ancestor chain, so a mixed cycle does not nest either. Mutual routing between workflows is therefore legal, and the hazard that blanket rule had been catching by accident is now caught deliberately by a cross-workflow escapability check (`:no_resolve_across_workflows`): seed from the workflows that reach a real Resolve unaided, spread backward along handoff edges, and refuse whatever is left. Only reached when the graph actually contains a handoff — with none, `GraphValidator`'s own `:no_path_to_resolve` already answers the question. And `WorkflowHealthCheck` does not call it a dead end
- **Two primitives answer "where does this run live", and nothing should infer it again.** `Scenario#run_origin` walks backward to the workflow the agent started in, alternating `root_scenario` and `handed_off_from`; `Scenario#run_head` walks forward along `handed_off_to` to the frame the run is on now. Neither link alone spans a mixed chain (`A --sub-flow--> B --handoff--> C --sub-flow--> D`), and one hop forward is not enough because the next frame may itself have handed on. `root_scenario` still answers the narrower question — the top of one *parent* chain — and is correct for "which script am I following", which is what the run header uses. Use `run_origin` for anything about the run as a whole: the transcript, and share/embed permission (the token belongs to the workflow the visitor opened, and a handed-to workflow has none). Four readers each derived this for themselves before, and three review rounds plus a spike each found a different one wrong — twice at the same line. See `docs/designs/handoff-spike-findings.md`
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
- **Strict AI dialect** — a JSON file carrying a top-level `schema_version: "1"` takes a separate, strict path: `StrictImportValidator` refuses what the lenient parser coerces (unknown step type, unknown field, duplicate/missing/malformed step id, dangling transition target, missing required field, a resolve step with transitions, a non-resolve step without them (except a `sub_flow` with `sub_flow_returns: false`, which ends the workflow and so must have none), invalid enum, invalid condition syntax, unknown/forbidden group, unresolvable sub-flow target) and reports every problem at once with a stable code, a JSON path and what was expected. It writes nothing: an upload renders a preview or an error report, and committing takes a second POST to `/workflows/import/commit`. `ImportSchemaGenerator` generates `public/schemas/turboflows-workflow-v1.json` from `StepFieldMap` and the models' `VALID_*` constants; `ImportPromptGenerator` builds the copyable agent prompt on the import page from that same schema. A file may carry a **set** of up to `ImportSchemaGenerator::MAX_WORKFLOWS_PER_FILE` workflows, imported together in one transaction, so a `sub_flow` step may name another workflow defined in the same file by title rather than needing it to exist and be published first — that chicken-and-egg is why a generated set of linked workflows was previously unimportable. Two workflows in one file may not share a title, since that is how an in-bundle target is matched, and a bundle whose sub-flows form an **all-returning** cycle, exceed `SubflowValidator::MAX_DEPTH` (10), name a target that vanished between preview and commit, or from which **no Resolve is reachable at all** (`:no_resolve_across_workflows`) is refused by `SubflowValidator` after insert and rolled back whole. A cycle of *handoffs* is not refused — that is a normal routing shape. Depth is refused at import even though `WorkflowHealthCheck` files it as a `:warning`, because `Workflow#validate_subflow_circular_references` copies a save-blocking `SubflowValidator` finding onto the record on **every save** — letting a 15-deep chain import produced fifteen workflows that could never be saved or published again. Which findings block a save is now an explicit allowlist, `SubflowValidator::SAVE_BLOCKING_CODES` (`circular_subflow`, `max_depth_exceeded`, `subflow_target_missing`) — an allowlist, not a denylist, so a finding added later is inert at save time until someone opts it in. `:no_resolve_across_workflows` is deliberately absent: a bundle is wired leaf-first and is legitimately inescapable while half-built, so it must stay saveable. Publish and import commit refuse it; the builder shows it as a warning. **A bundle lands as drafts referencing drafts, so publish it leaf-first — and when it references itself, leaf-first does not exist.** Whichever member of a cycle you publish first still points at a draft, which is why `WorkflowSetPublisher` exists: it walks the root's transitive draft dependencies and publishes them in one transaction, with each member carrying the set's ids in `Workflow#publishing_alongside` so `validate_subflow_steps` accepts a target going live in the same breath. That relaxes the rule's *timing*, never the rule — nothing is left pointing at a draft, and handoffs are **not** exempted. Publishing a workflow whose closure is larger than itself redirects to a confirmation page first. `Workflow#validate_subflow_steps` asks for a published sub-flow target only inside `Workflow#while_publishing`, the save `WorkflowPublisher` makes to go live, and so do the graph-structure check and the blank-target check. They keyed on `published?`, which says a workflow is live rather than being published, and a live workflow is edited in place, so its title and Details saves were refused mid-edit; `WorkflowHealthCheck` marks the step `:subflow_target_unpublished` (a warning) so the ordering is visible in the builder rather than arriving as a failed publish. Export emits this dialect, so an exported file is a valid strict import file — with one deliberate exception: a workflow containing a `select` form field with no `select_options` exports to a file the validator refuses (`missing_select_options`). Nothing could write that key before 2026-09-04, so such a field was always an unanswerable dropdown; `WorkflowHealthCheck` flags it as `:select_options_required` on the step so it can be fixed before exporting. There is a second such exception, and it is the price of drafts referencing drafts: a workflow whose sub-flow target is still a draft exports to a file the validator refuses (`sub_flow_target_not_published`), because export emits the target by title and the validator resolves an out-of-bundle title against published workflows only. Publish the target — or export the set together once bundle export exists. A third exception comes from what the builder lets you save: a step with a blank title, or a Question with blank question text, exports to a file the validator refuses (`missing_required_field`). The step panel saves them anyway, because letting the browser refuse the save lost the edit, and neither blocks a publish. `WorkflowHealthCheck` flags them as `:title_required` and `:question_text_required`. A workflow ending in a **handoff** does round-trip: `ImportSchemaGenerator` makes `transitions` conditional on `sub_flow_returns` via `if`/`then`/`else`, and the `else` is load-bearing — a *returning* sub_flow with nowhere to go is still refused. A file with no `schema_version` is untouched and keeps the lenient behaviour
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
```

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
- `_flow_diagram_panel.html.erb` — read-only BFS flow diagram in the panel
- `_settings_panel.html.erb` — workflow metadata (description, who can see it, tags, sharing)
- `_health_panel.html.erb` — health validation results (errors, warnings, passing checks with Fix buttons)
- `_empty_state.html.erb` — shown when no steps; includes template archetype cards

**Key Stimulus controllers:**
- `builder_controller.js` — panel open/close, step selection, title autosave, Escape to close, `openHealth` action, auto-opens health panel when `?health=true` URL param is present
- `step_list_controller.js` — SortableJS reorder + type picker popover
- `inline_autosave_controller.js` — debounced autosave (2s), listens for `lexxy:change` events, flushes pending saves on disconnect via `FormData` + `fetch`, dispatches `health:check-needed` after disconnect saves
- `step_warnings_controller.js` — async health check fetch, renders inline warning icons on step rows, toolbar issue count, click-to-open popover with Fix buttons. Listens for `turbo:submit-end`, `health:check-needed`, `turbo:before-stream-render`
- `template_picker_controller.js` — template popover in toolbar, applies workflow archetypes

**Autosave pattern:** Every field change triggers `inline-autosave#schedule` (via `data-action` on inputs or `lexxy:change` listener on the form). On disconnect (e.g., switching steps), pending saves are flushed by snapshotting `FormData` and sending via `fetch()` POST with `_method=patch`. The step panel form carries `novalidate`: `requestSubmit()` runs the browser's required-field check, and while any `required` field was empty (a new Question's text, a Form row just added) every save was refused and the edit dropped. The health check says what still needs filling in.

**Mode:** `data-builder-mode-value="view|edit"` on the builder container. CSS hides drag handles, add/delete buttons, and edit-only elements in view mode.

**Inline Validation + Health Panel:**
- `step_warnings_controller.js` fetches `/workflows/:id/health.json` asynchronously (debounced 500ms) after every autosave or Turbo Stream update
- Warning icons appear inline on step rows with issue counts; clicking opens a popover with issue details and Fix buttons
- Toolbar shows aggregate issue count next to step count; clicking opens the Health panel in the slide-in panel
- Health panel (`_health_panel.html.erb`) shows categorized Errors/Warnings/Passing sections with clickable step links and Fix buttons
- Fix buttons (`connect_next`, `add_resolve_after`) are deterministic, additive autocorrects that respond with Turbo Streams to update both the step list and health panel
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
- `StepBuilder` — creates AR steps from hash data. Auto-creates sequential transitions when no explicit transitions provided. Validates at least one Resolve step exists. Also provides `StepBuilder.normalize` (class method), its own helper, which `WorkflowImporter` borrows.
- `ScenarioStepProcessor` — extracted step-processing logic for Scenario. Calls public methods on Scenario (`advance_to_next_step`, `resolve_at_current_step`, `record_completion`).
- `GraphValidator` — graph validation: reachability from start_step, terminal nodes must be Resolve steps, and **escapability** — from every step reachable from the start, some path must reach a terminal Resolve (`:no_path_to_resolve`). It does **not** reject cycles: a retry loop is a normal call-centre shape, and what is refused is a loop with no way out. This replaced an acyclic check; for an acyclic graph the rule asserts nothing new, since every node in a finite DAG already reaches a terminal and terminals must be Resolve steps.
- `SubflowValidator` — sub-flow graph rules. Refuses an **all-returning** cycle (a handoff leaves no stack frame, so only a returning cycle nests), caps returning nesting at `MAX_DEPTH` (10), reports a target that no longer exists, and refuses a set of workflows from which no Resolve is reachable (`:no_resolve_across_workflows` — seeded from workflows that reach a Resolve unaided, spread backward along handoff edges, and skipped entirely when the graph has no handoff, where `GraphValidator` already answers it). `SAVE_BLOCKING_CODES` names which of these block an ordinary save.
- `WorkflowSetPublisher` — publishes a workflow together with every draft it transitively depends on, in one all-or-nothing transaction, so workflows that reference each other can go live at all. `closure_for(root)` previews the set without writing. Checks `can_be_edited_by?` across the **whole** closure, not just the root — publishing your own workflow must not publish someone else's draft that yours happens to reference.
- `StrictImportValidator` — validates a strict-dialect file without writing: envelope, structure, graph (same `GraphValidator` publish runs), semantics (condition syntax, undefined variables, unmatched option values), and external references (groups via `WorkflowPlacement`, sub-flow targets scoped to `Workflow.visible_to`). Returns a `Report` of errors and warnings; `WorkflowImporter` takes a valid one via `strict_report:` and only writes.
- `ImportSchemaGenerator` / `ImportPromptGenerator` — the published JSON Schema and the agent prompt, both generated from the models so neither can drift from what the app accepts.
- `WorkflowHealthCheck` — aggregates GraphValidator + SubflowValidator + step-level checks into a per-step issue map. Returns `Data.define` Result with issues keyed by step UUID, severity levels, fixable flags, and summary counts. Used by both the health panel (HTML) and async JS fetch (JSON).
- `WorkflowPublisher` — publishes workflow versions with full graph validation. Uses `Workflow#validation_graph_hash`.
- `FlowDiagramService` — BFS layout for the builder's flow diagram panel.

**Constraints enforced:**
- Transitions must connect steps within the same workflow (cross-workflow via SubFlow only)
- Every workflow must have at least one Resolve step
- All terminal nodes must be Resolve steps (on publish)
- Every step must be able to reach a Resolve. Cycles are allowed; unescapable ones are not
- Step UUIDs are immutable after creation
- Optimistic locking on both Workflow and Step (`lock_version`)

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
  destination is a labelled link — Workflows, Play, Analytics, Admin — not a menu. The
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
  light Analytics. Those first three used to light nothing — you could be
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
- **A run's idle clock is the whole run, never one frame.** `Scenario#run_frames` — seeded from `run_origin`, closed over child/parent **and** handoff links in both directions — is the sixth reader of run topology and the first to enumerate a whole run. `belongs_to :parent_scenario` has no `touch:`, so a parent parked on a *live* sub-flow has a clock that stopped when it parked, and `run_head` returns exactly that parent, because neither it nor `run_origin` descends into an ordinary sub-flow child. Keying on either settles runs an agent is still working. `run_frames` drives both the clock and the settle so the two cannot disagree. Do **not** fix this with `touch: true`: it puts N ancestor writes and N optimistic locks in the runner's hot path per sub-flow step, and still misses handoff chains. `time_out!` is named around the enum's own `timed_out!`, which flips the status and records nothing — the shape of bug (2) above. See `docs/designs/idle-sweep-spike-findings.md`
- **Trend history is rolled up before the runs are deleted, and which days get rolled is the whole design.** `ScenarioRollupBuilder` writes `scenario_rollups` (workflow x day x purpose x outcome -> count, duration SUM + COUNT) and `scenario_dropoff_rollups` (workflow x day x step_title), via `RollUpScenariosJob` at **02:30 — between the sweep (02:00) and cleanup (03:00)**, an order that is load-bearing on the first night and guarded by `test/integration/recurring_schedule_order_test.rb`. The obvious rule — re-roll every day that still has raw rows — **corrupts history**: cleanup keys on `completed_at` while a rollup keys on `started_at`, so a day's runs are deleted across several nights, and recomputing from the survivors undercounts and then freezes at the wrong number. So a day is rolled only while it is still moving: it has no rollup rows yet (first run, or a missed night), or it falls inside `REFRESH_DAYS`. Writes are **delete-then-insert, not upsert** — a run that settles moves from `"pending"` to its real outcome, and an upsert leaves the stale pending row behind. Durations are a SUM and a COUNT, never an average, so averages compose across days. Drop-off needs its own table because the step is read from `execution_path.last`, which no aggregate of outcomes can reconstruct
- **Analytics has two modes and never stitches them.** Within retention it reads individual runs and every filter works. **"All time"** (`params[:range] == "all"`, administrators only, since a rollup has no agent to limit to a manager's team) reads the rollups instead: it reaches past the horizon but cannot answer per-agent, per-step or time-of-day questions, so those panels render `_rollup_unavailable` rather than an empty table, the run-level filters are hidden rather than shown inert, and CSV export redirects rather than handing over 90 days labelled "all time". A blended view would be exact for recent ranges and quietly partial for older ones — the exact failure the rollups exist to remove. **Every rate divides by finished runs**, and `Scenario::COMPLETED_OUTCOMES` (completed, resolved, escalated, transferred) is what counts as completed — in both modes and on every tab, headline and Workflows and Agents alike. A run still going has not failed to complete, and escalating or handing off are endings a workflow is built to reach. A run with no outcome reads **In progress** (a rollup's `pending` too); the label and bar colour come from `AnalyticsHelper`
- **The analytics headline counts calls; the tables count runs.** A call starts in one workflow and can pass through several — a returning sub-flow is a child scenario, a handoff a new one — so counting scenario rows read two routed calls as "Total Runs 10" and averaged their durations piecewise (fixed 2026-09-12). `CallStatistics` counts origins (neither `parent_scenario_id` nor `handed_off_from_id`) from the page's filtered scope, so every filter means where the call *started*; a call's outcome and finish come from its ending, chosen in SQL as `Scenario#run_ending` chooses it, and `CallStatisticsTest` holds the two to the same answer shape by shape. Durations are two timestamps subtracted in Ruby, not SQL date math, because SQLite and Postgres spell it differently. Every frame records its call in `scenarios.run_origin_id` (NULL on an origin, set in `before_create` from the link it is born with), because SQL cannot walk `run_origin`. The stat cards, outcome breakdown and Calls Over Time read calls; Workflows, Agents, step performance, drop-off and CSV stay per run. **All time counts calls too** — `scenario_rollups` carries `calls_count` and call duration sums on the same grain, keyed by the call's starting workflow and day and its ending outcome — but days rolled before the columns existed hold zero calls and were deliberately not backfilled (re-rolling part-cleaned days is the undercount trap below), so the page says from when calls are counted
- **Analytics is for administrators and the managers of groups, and `AnalyticsScope` decides what each sees.** A CSR manager must not become an administrator to coach their team, so an Admin marks someone as manager of a group on the group page (`group_managers`, deliberately not a flag on `user_groups`, which people join and leave themselves), whatever their role. `AnalyticsScope.new(user)` is the one answer to "whose runs": an administrator every run; a manager runs by members of the managed groups and their sub-teams, read at request time; anyone else none. `AnalyticsController` (now `/analytics`, outside the admin shell, which stays admin-only in every controller), its filter lists, its CSV and the read-only drill-down (`Analytics::AgentsController` for one agent's calls, `Analytics::RunsController` for one call, both through `AnalyticsAccess`) all ask it. Scoping is by who ran it, so a handed-off call stays whole and a manager sees their team's runs on workflows they cannot open. Managers get 7, 30 and 90 days: All time reads rollups, which carry no agent. An out-of-scope agent or run and a nonexistent id get the same redirect. Team membership is what a manager's view rests on, so a CSR must be a member of their team group, and a self-joinable team's manager sees whoever joins it. A manager in no group of their own still counts as awaiting groups — the Overview, the admin sidebar badge, and `/welcome` after every sign-in all flag them the same as anyone else with no group, and they see only Global workflows in Play — so make each manager a member of their own team. The Managers card marks any manager in no group ("In no group"), reading the same `User.awaiting_groups` scope as the Overview so the two cannot disagree
- **A workflow version's RECORD is permanent; only its restorable payload has a limit.** Nothing is ever deleted — `workflows.published_version_id` is a RESTRICT foreign key, and a design that removed rows would have to reason about that on every path. `WorkflowVersion#strip_snapshot!` nulls `steps_snapshot` and stamps `stripped_at`, keeping the number, date, publisher, title and changelog: `metadata_snapshot` is ~265 bytes against ~9.5KB of steps, so the history costs ~3% of the storage. The newest `WORKFLOW_VERSION_RESTORE_LIMIT` (default 10) stay restorable — a **count**, not an age, because a workflow published twice a year is exactly where you have forgotten what changed. Released **on publish**, not nightly: the rule is a count and only a publish can push a version past it, so a scheduled scan would hunt for work `WorkflowPublisher#release_old_snapshots!` already knows about. The existing backlog was closed once by a migration, since a workflow published fifty times and then abandoned is never published again
- **Republishing unchanged content reuses the existing version.** `WorkflowPublisher` compares both `steps_snapshot` and `metadata_snapshot` (a rename with identical steps IS a change) and skips the write when they match. This compounds through `WorkflowSetPublisher`, which publishes a whole dependency closure: a ten-workflow set republished for one change wrote ten versions, nine identical. Unlike releasing a snapshot, skipping the write destroys nothing. `version_number` is display-only, so gaps are harmless — but note two existing tests had to change, because both republished unchanged content and asserted a v2
- **The changelog is written retroactively, from the versions list, by anyone who `can_be_edited_by?`.** Publishing a single workflow is one `button_to` click; a dialog there to capture an optional field is the one people dismiss, which buys the friction and the empty column both. `published_by` is never touched, so authorship of the publish survives someone else annotating it. A released version is still annotatable — the record is the durable artefact. The versions list paginates (`Workflows::VersionsController::PER_PAGE`) because that record now only grows, and the compare dropdowns offer only restorable versions: a diff reads `steps_snapshot` on both sides, and a menu should not list what it cannot do
- **`scenarios.workflow_version_id` records which script the agent followed**, set by a `before_create` on `Scenario` rather than at the four `Scenario.create!` sites — a sub-flow child runs a *different* workflow and must record that workflow's version. It is nil for a simulation of an unpublished draft, which is correct. It does **not** hold a snapshot alive: the link answers *which* version, and that is kept permanently anyway. The column, its index and its FK existed for a long time with nothing writing them (0 of 120 rows), and there was no `belongs_to` either
- Data lifecycle: tiered scenario retention (7-day simulation, 90-day live), batched cleanup via `CleanupScenariosJob` + `CleanupDraftsJob` (daily at 3 AM), admin visibility at `/admin/data_health`, whose "For whoever runs the server" disclosure lists the env vars with their current values, the rake commands, and the schedule read from `config/recurring.yml`. **A draft with steps is never auto-deleted** — both draft-cleanup scopes require the workflow to have none. `orphaned_drafts` also requires the title `"Untitled Workflow"` and 24 hours; `expired_drafts` requires a `draft_expires_at` in the past. Imports carry a nil TTL, so they match neither
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
- Recurring jobs configured in `config/recurring.yml` (cleanup scenarios + drafts daily at 3 AM)
- Retention configurable via ENV: `SCENARIO_RETENTION_SIMULATION_DAYS` (default 7), `SCENARIO_RETENTION_LIVE_DAYS` (default 90), `SCENARIO_IDLE_TIMEOUT_HOURS` (default 24 — the sweep runs nightly, so the real window is this plus up to a day)
- Pre-deploy: RuboCop + full test suite (run locally before deploy)
- The `20260911120000_add_self_join_to_groups` migration makes every existing group self-joinable (`admins_add_members` defaults to `false`), and sign-up is open — right after deploying, an administrator should mark sensitive groups "Only administrators add people" before the feature is announced
