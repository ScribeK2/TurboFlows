# AGENTS.md

This file provides guidance to AI coding agents working with TurboFlows.

## What is TurboFlows?
A straightforward workflow creator for call/chat centers to build, simulate, and manage post-onboarding training + client troubleshooting flows with drag-and-drop simplicity.

- Seven step types: Question, Action, Sub-Flow, Message, Escalate, Resolve, Form
- A Sub-Flow either returns (call/return, the default) or **hands the run over** (`steps.sub_flow_returns: false`, a tail call: the step ends this workflow, takes no transitions and needs no Resolve after it). `Scenario#run_origin` and `Scenario#run_head` are the only two answers to "where does this run live" — never infer it again. Both in full: `docs/agents/workflow-engine-and-import.md`
- All workflows are graphs — every step connects via explicit Transitions (no separate "linear mode")
- Every workflow must have at least one Resolve step (the only always-terminal type)
- Scenario Mode: interactive step-by-step graph traversal with variable interpolation {{var}}, sub-flow recursion, safety limits
- Player Mode: user-facing workflow execution UI for agents on live calls/training. Separate layout, share links, embed mode. Shares the step body with Scenario mode via `app/views/runner/` partials
- Sharing: workflows can generate share tokens (`/s/:share_token`) for anonymous access, with optional iframe embedding
- Tags: workflow categorization with tag pills, autocomplete, and search integration
- Real-time collaboration via Action Cable (WorkflowChannel presence)
- Hierarchical Groups (up to 5 levels) + Folders + drag-and-drop organization
- Workflow templates: YAML-driven archetypes (`WorkflowTemplate`) loaded from `config/templates.yml` (5 presets: Guided Decision, Verification Checklist, Triage & Escalate, Diagnosis Flow, Simple Handoff)
- Import/export (JSON/CSV/YAML/MD → JSON/PDF via Prawn). Every import lands as a draft with no expiry. A JSON file with a top-level `schema_version: "1"` takes the **strict AI dialect** path (`StrictImportValidator`, preview then commit, bundles of linked workflows, `WorkflowSetPublisher`). Export emits that dialect, with four documented exceptions. In full: `docs/agents/workflow-engine-and-import.md`
- No Node.js: pure Hotwire (Turbo + Stimulus), importmap + Propshaft, vanilla CSS (@layer + OKLCH tokens)
- Rails 8.1, Devise auth (roles: Administrator / Editor / User), optimistic locking (lock_version)

## Topic guides — read the one for the area BEFORE you change it

Most of what used to be in this file lives in `docs/agents/`, so a session pays for
it only when it needs it. They are not background reading: each records traps that
cost someone an afternoon, rulings that were argued out, and the tests that guard
them. **Read the matching guide in full before editing, reviewing or debugging in
its area, and when you hand such work to a subagent, tell it to read the guide too.**
Code comments that say "see AGENTS.md § Growing a workflow" (or another builder
heading) mean `docs/agents/builder.md`.

| If the work touches… | Read |
|---|---|
| The builder at `workflows/:id`: step list and rows, the step panel and its autosave, the save indicator, `Step::Doors`, `GrowStep`, `TransitionSync` (`rendered`/`minted`/`known`), `Steps::TransitionsController`, the type picker, the target-picker dialog, deleting a step, builder system tests, the health panel and Fix buttons | `docs/agents/builder.md` |
| `StepResolver`, `ConditionEvaluator` (a condition value has TWO readings), `GraphValidator`, `SubflowValidator`, `WorkflowHealthCheck` codes, `WorkflowPublisher` / `WorkflowSetPublisher`, sub-flow handoffs, `run_origin` / `run_head`, import/export, `StrictImportValidator`, the import schema and prompt | `docs/agents/workflow-engine-and-import.md` |
| `RunnerShell`, `ScenariosController`, `PlayerController`, `app/views/runner/`, the thread, share links and anonymous runs, Cancel/stop, refusal announcements and focus, auto-advance | `docs/agents/runner-and-player.md` |
| Anything under `Admin::`, `Admin::Attention`, `JobHealth`, Data Health, who sees a workflow (`Group.reachable_ids_for`, Global, `no_audience`), self-join and `/welcome`, the Users and Groups pages, group depth, group pickers | `docs/agents/admin-and-groups.md` |
| `/` for a CSR or for an Editor/Admin, `Dashboard::DataLoader`, pins, "From your team", featured workflows, `/teams`, `TeamCuration`, `sortable-list` | `docs/agents/home-and-teams.md` |
| Scenario retention and the idle sweep, `run_frames`, rollups, Analytics (`CallStatistics`, `AnalyticsScope`, All time), workflow versions and changelogs, `workflow_version_id`, draft cleanup, uploaded-file cleanup, the nightly job order | `docs/agents/data-lifecycle-and-analytics.md` |

## Development Commands

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
  are that wait. There are two places a wait must NOT be added, because the gap
  is the race: in `builder_grow_test.rb`, between typing the title and pressing
  "New step" ("growing inside the autosave window…"); and in
  `builder_grow_races_test.rb`, between choosing an answer type and pressing a
  door ("a door pressed before the answer-type save lands…"). The mutation
  check — make `TransitionSync#call` start its transaction with
  `@step.transitions.destroy_all` — belongs since 2026-09-19 to a third test,
  also in the races file, "a connection written elsewhere while the panel is
  open…": a grow now waits for the panel's pending save, so the first test
  passes under that mutation and only that one fails, on its transitions
  assertion.

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
the step panel. `docs/agents/builder.md` § Growing a workflow says what it answers
with and why a refusal has to render inside the dialog.

## Workflow Engine

All workflows are graphs. There is no separate "linear mode" — a sequential flow is just a graph where each step has one transition to the next.

**Key services:** one entry each, with the rulings behind them, in `docs/agents/workflow-engine-and-import.md`.

**Constraints enforced:**
- Transitions must connect steps within the same workflow (cross-workflow via SubFlow only)
- Every workflow must have at least one Resolve step
- All terminal nodes must be Resolve steps (on publish)
- Every step must be able to reach a Resolve. Cycles are allowed; unescapable ones are not
- Step UUIDs are immutable after creation
- Optimistic locking on both Workflow and Step (`lock_version`)

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

- No multi-tenancy (single install/org), but strong group-based access
- Background jobs: Solid Queue (in-process via Puma plugin, `config/recurring.yml` for schedules)
- Retention, the idle sweep, rollups, Analytics, workflow versions and uploaded-file cleanup: `docs/agents/data-lifecycle-and-analytics.md`

## UI Guide
Read `UIGUIDE.md` before creating or modifying any view or stylesheet. It is
deliberately not imported here, so it costs nothing in a session that touches no
UI. For Claude Code, `app/views/CLAUDE.md` and `app/assets/stylesheets/CLAUDE.md`
— each one line importing it, and the only two `CLAUDE.md` files `.gitignore`
lets through — load it automatically when work reaches those directories.

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
- The `Step::Doors` position rule (2026-09-19) changes what an existing workflow SHOWS, not how it runs: a workflow whose default connection is sorted above a conditional one (only an import could write that) opens after this deploy with those answers reading as stubs and a `:shadowed_connection` warning. That is the routing it always had; the warning's Fix re-sorts it. No migration, no operator step
- The `rendered`/`minted` deploy (2026-09-19) has the same shape of cutover window, narrower than it first looks because of the transitional `known` key: a NEW-JavaScript tab's hidden `transitions_json` field holds whatever the server last rendered into it — `known` included — UNTIL `saveTransitions` overwrites it, which only happens when the author actually adds, removes or edits a connection in that panel (`step_transitions_controller.js#connect`/`#refresh` never call `saveTransitions`, so opening the panel and editing some OTHER field never touches it). So a save that never touched connections still carries `known` and an OLD container's `TransitionSync#parse` accepts it and reads it legacy-style, correctly — nothing is refused. Only a save made AFTER the connections editor was touched sends the current shape (`{rendered, minted, rows}`, no `known`), and THAT one an OLD container refuses: `TransitionSync#parse` requires `known` present as an Array or raises `Malformed` ("This step was saved, but its connections were not…") — the step's own fields still save first (`@step.update` runs before `sync_transitions`), so no TRANSITION is written or deleted on that request, but the rest of the PATCH did write. It clears as soon as the cutover completes and every request reaches a new container
