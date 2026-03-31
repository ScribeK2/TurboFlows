# Architecture

## Tech Stack

| Layer | Technology |
|-------|-----------|
| **Framework** | Ruby on Rails 8.1 (#nobuild — no Node.js required) |
| **Frontend** | Hotwire (Turbo + Stimulus), ~69 Stimulus controllers |
| **Styling** | Vanilla CSS (@layer cascade, OKLCH design tokens, Propshaft) |
| **Database** | SQLite (dev/test), PostgreSQL (production) |
| **Real-time** | Action Cable (Redis in production, in-memory in dev) |
| **Auth** | Devise with lockable accounts |
| **PDF** | Prawn |
| **Rich Text** | Action Text + Lexxy (Lexical-based editor) |
| **JS (vendored)** | SortableJS, Fuse.js, spark-md5 |
| **Monitoring** | Sentry (sentry-rails) |
| **Security** | Rack::Attack, Brakeman, Bullet (N+1 detection) |
| **Linting** | RuboCop (with rails, minitest, performance plugins) |
| **Deployment** | Kamal, Puma |

## Features

### Workflow Builder
- **Seven step types** — Question, Action, Sub-Flow, Message, Escalate, Resolve, and Form
- **Unified builder** — Single-page interface with step list + slide-in detail panel
- **Drag-and-drop ordering** with SortableJS
- **Sub-flow support** — Call other workflows as reusable sub-routines with circular reference detection
- **Rich text content** — Action Text editor (Lexxy/Lexical)
- **Multi-branch decisions** — Condition builder with presets and variable autocomplete
- **Autosave** — All changes saved automatically with debounced persistence
- **Read-only / edit mode** — Role-based access
- **Optimistic locking** — Concurrent editing protection via `lock_version`

### Scenario Mode
- **Step-by-step execution** — Walk through any workflow interactively
- **Graph traversal** — Follows branches and connections through the workflow graph
- **Variable interpolation** — `{{variable}}` syntax resolved at runtime
- **Sub-flow execution** — Spawns child scenarios for sub-flow steps
- **Safety limits** — Iteration cap, execution timeout, and nested condition depth limit

### Player Mode
- **User-facing execution** — Standalone UI for agents on live calls and new hire training
- **Minimal progress stepper** — Color-coded dots showing completed steps at a glance
- **All answer types** — Yes/no, multiple choice, dropdown, number, date, text, and form
- **Clipboard copy** — One-click copy of action step instructions
- **Share links** — Generate anonymous access links (`/s/:token`) for external users
- **Embed mode** — Iframe-embeddable player with hidden chrome
- **Separate layout** — Own header, footer, and CSS (`_player.css`), independent of the builder

### Collaboration & Real-Time
- **Action Cable presence** — See who is editing a workflow in real time
- **Optimistic locking** — Prevents conflicting saves with automatic conflict detection

### Organization
- **Hierarchical groups** — Nested groups (up to 5 levels) with recursive membership
- **Folders** — Organize workflows within groups with drag-and-drop reordering
- **Template library** — Save and reuse workflows as templates
- **Search and filtering** — Client-side fuzzy search (Fuse.js) across workflows

### Import & Export
- **Import** from JSON, CSV, YAML, or Markdown
- **Export** to JSON or PDF (Prawn)

### Access Control
- **Three roles** — Administrator, Editor, User with granular permissions
- **Group-based visibility** — Workflows inherit access from group membership
- **Account security** — Devise authentication with lockable accounts, rate limiting (Rack::Attack)

### Tags
- **Workflow tagging** — Categorize workflows with reusable tags
- **Autocomplete** — Tag selector with search-as-you-type
- **Dashboard pills** — Tags shown on workflow cards and in search results

### Admin Panel (`/admin`)
- User management with role assignment, password resets, and bulk group assignment
- Template management
- Group and folder hierarchy management
- Workflow overview and monitoring
