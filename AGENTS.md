# AGENTS.md

This file provides guidance to AI coding agents working with TurboFlows.

## What is TurboFlows?
A straightforward workflow creator for call/chat centers to build, simulate, and manage post-onboarding training + client troubleshooting flows with drag-and-drop simplicity.

- Seven step types: Question, Action, Sub-Flow, Message, Escalate, Resolve, Form
- All workflows are graphs — every step connects via explicit Transitions (no separate "linear mode")
- Every workflow must have at least one Resolve step (the only always-terminal type)
- Scenario Mode: interactive step-by-step graph traversal with variable interpolation {{var}}, sub-flow recursion, safety limits
- Player Mode: user-facing workflow execution UI for agents on live calls/training. Separate layout, read-only progress stepper, share links, embed mode
- Sharing: workflows can generate share tokens (`/s/:share_token`) for anonymous access, with optional iframe embedding
- Tags: workflow categorization with tag pills, autocomplete, and search integration
- Real-time collaboration via Action Cable (WorkflowChannel presence)
- Hierarchical Groups (up to 5 levels) + Folders + drag-and-drop organization
- Workflow templates: YAML-driven archetypes (`WorkflowTemplate`) loaded from `config/templates.yml` (5 presets: Guided Decision, Verification Checklist, Triage & Escalate, Diagnosis Flow, Simple Handoff)
- Import/export (JSON/CSV/YAML/MD → JSON/PDF via Prawn)
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

- `Workflow` — container with versions (`workflow_version.rb`), autosave, optimistic locking (`lock_version`)
- `Step` — STI base class (`app/models/step.rb`); subclasses in `app/models/steps/` (Question, Action, SubFlow, Message, Escalate, Resolve, Form). UUID-based identification (immutable via `attr_readonly`). Includes `Step::Positionable` concern for ordering.
- `Tag` / `Tagging` — workflow categorization (polymorphic tagging)
- `Transition` — directed edges between steps (same workflow only). Supports conditional expressions via `ConditionEvaluator`, simple value matching, and position-ordered evaluation (first match wins).
- `Scenario` — simulation runner. Always uses graph traversal via `StepResolver` and `current_node_uuid` tracking. Spawns child scenarios for sub-flows, enforces iteration limits on circular graphs.
- `Group` / `Folder` — hierarchical org (recursive membership, cascade permissions)
- `User` — Devise model with roles (Administrator / Editor / User)
- `WorkflowTemplate` — YAML-driven workflow archetypes loaded from `config/templates.yml`; `StepTemplate` — step-level template definitions

## Builder UI

The unified builder lives at `workflows/:id` — one URL for both viewing and editing. No separate wizard or editor views.

**Layout:** Header (three-zone grid: left = inline-editable title + status, right = Edit/Run Scenario/Publish/Export buttons) → Toolbar (step count, View Flow, Templates popover, Settings) → Main area (step list + slide-in panel). Empty state shows template archetype cards for quick-start.

**Key views:**
- `_builder.html.erb` — main layout, renders step list + empty Turbo Frame panel
- `_step_list.html.erb` / `_step_row.html.erb` — compact step rows with SortableJS drag-and-drop
- `steps/_panel_edit.html.erb` — step editor loaded via Turbo Frame into the panel
- `_flow_diagram_panel.html.erb` — read-only BFS flow diagram in the panel
- `_settings_panel.html.erb` — workflow metadata (description, groups, public toggle)
- `_empty_state.html.erb` — shown when no steps; includes template archetype cards

**Key Stimulus controllers:**
- `builder_controller.js` — panel open/close, step selection, title autosave, Escape to close
- `step_list_controller.js` — SortableJS reorder + type picker popover
- `inline_autosave_controller.js` — debounced autosave (2s), listens for `lexxy:change` events, flushes pending saves on disconnect via `FormData` + `fetch`
- `template_picker_controller.js` — template popover in toolbar, applies workflow archetypes

**Autosave pattern:** Every field change triggers `inline-autosave#schedule` (via `data-action` on inputs or `lexxy:change` listener on the form). On disconnect (e.g., switching steps), pending saves are flushed by snapshotting `FormData` and sending via `fetch()` POST with `_method=patch`.

**Mode:** `data-builder-mode-value="view|edit"` on the builder container. CSS hides drag handles, add/delete buttons, and edit-only elements in view mode.

## Real-Time & Collaboration

- WorkflowChannel (Action Cable) — presence (who's editing), live updates
- In-memory cable in dev; Redis in production
- Optimistic locking prevents save conflicts

## Workflow Engine

All workflows are graphs. There is no separate "linear mode" — a sequential flow is just a graph where each step has one transition to the next.

**Key services:**
- `StepResolver` — graph traversal engine. Evaluates transitions in position order, handles conditional branching (via `ConditionEvaluator`), simple value matching for Question answers, and SubFlow markers.
- `StepBuilder` — creates AR steps from hash data. Auto-creates sequential transitions when no explicit transitions provided. Validates at least one Resolve step exists.
- `StepSyncer` — incremental sync for step persistence. Upserts, deletes, and reconciles transitions atomically.
- `GraphValidator` — DAG validation (cycle detection, reachability from start_step, terminal nodes must be Resolve steps).
- `SubflowValidator` — prevents circular sub-flow references (max depth: 10).
- `WorkflowPublisher` — publishes workflow versions with full graph validation.
- `FlowDiagramService` — BFS layout for the builder's flow diagram panel.

**Constraints enforced:**
- Transitions must connect steps within the same workflow (cross-workflow via SubFlow only)
- Every workflow must have at least one Resolve step
- All terminal nodes must be Resolve steps (on publish)
- Step UUIDs are immutable after creation
- Optimistic locking on both Workflow and Step (`lock_version`)

## Player Mode

The Player is the user-facing workflow execution UI, separate from the builder's Scenario mode. It has its own layout, routes, and controller.

**Routes:** `/play` (index), `/play/:id` (start), `/player/scenarios/:id/step` (step), `/player/scenarios/:id/show` (completion), `/s/:share_token` (shared anonymous access)

**Key files:**
- `app/controllers/player_controller.rb` — start, step, next_step, back, show, show_shared
- `app/views/layouts/player.html.erb` — standalone layout (header, main, footer)
- `app/views/player/step.html.erb` — step execution with progress stepper, clipboard, cancel
- `app/views/player/show.html.erb` — completion screen with stats
- `app/views/player/index.html.erb` — workflow card grid
- `app/helpers/player_helper.rb` — `player_back_button` helper (uses Player routes, not Scenario routes)
- `app/assets/stylesheets/_player.css` — Player-specific layout and component styles

**Key differences from Scenario mode:**
- Operates on AR Step objects (`@current_step`), not execution path hashes (`step['field']`)
- Uses `player_scenario_*_path` routes, not `*_scenario_path` routes
- Cancel button hidden for anonymous/shared scenarios (no Player index to return to)
- Progress stepper is read-only minimal dots (not the builder's interactive pill breadcrumbs)
- Supports all answer types: yes/no, multiple choice, dropdown, number, date, text, form

## Navigation & Search

- `NavController` (Rails) — `menu` and `search_data` endpoints for the global navigation UI
- `nav_search_controller.js` — Cmd+K fuzzy search (Fuse.js) across workflows, respects user permissions
- `nav_menu_controller.js` — navigation menu dropdown
- `dialog_manager_controller.js` — single-open dialog enforcement
- Three-zone header: logo center, search left, actions right

## Other Highlights

- Rich text: Action Text + Lexxy (Lexical editor)
- Global search: Fuse.js (Cmd+K via `nav_search_controller.js`)
- Drag-and-drop: SortableJS
- No multi-tenancy (single install/org), but strong group-based access
- Background jobs: Active Job (expandable to Solid Queue)
- Security: Rack::Attack, Bullet (N+1), Brakeman

## UI Guide
@UIGUIDE.md

## Coding Style
@STYLE.md

## Tools
Playwright MCP (for UI/system testing). Point agent to running app at `http://localhost:3000` (after `bin/dev`). Allows browser control (click, type, snapshot, inspect) — ideal for testing the builder, Scenario simulation, and drag-and-drop.

## Deployment Notes

- Branch: `main`
- Tool: Kamal + Puma + PostgreSQL
- Pre-deploy: RuboCop + full test suite
