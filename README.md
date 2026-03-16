<p align="center">
  <img src="public/favicon.svg" alt="TurboFlows logo" width="64" height="64">
</p>

<h1 align="center">TurboFlows</h1>

<p align="center">
  A workflow builder for call and chat centers — create, run, and manage training and troubleshooting flows with drag-and-drop simplicity.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Ruby_on_Rails-8.1-cc0000?logo=rubyonrails" alt="Rails 8.1">
  <img src="https://img.shields.io/badge/Ruby-4.0-cc342d?logo=ruby" alt="Ruby 4.0">
  <img src="https://img.shields.io/badge/Hotwire-Turbo_+_Stimulus-5200ff" alt="Hotwire">
  <img src="https://img.shields.io/badge/Vanilla_CSS-OKLCH_%2B_%40layer-4f46e5" alt="Vanilla CSS">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

---

## Features

### Workflow Builder
- **Six step types** — Question, Action, Sub-Flow, Message, Escalate, and Resolve
- **Drag-and-drop ordering** with inline step creation and collapsible cards
- **Two editing modes** — Linear (sequential list) and Graph Mode (visual node editor with connections via dagre/leader-line)
- **Sub-flow support** — Call other workflows as reusable sub-routines with circular reference detection
- **Rich text content** — Action Text editor (Lexxy/Lexical) for step instructions, messages, and notes
- **Multi-branch decisions** — Visual condition builder with presets and variable autocomplete
- **Autosave and optimistic locking** — Concurrent editing protection via `lock_version`

### Scenario Mode
- **Step-by-step execution** — Walk through any workflow interactively, recording inputs and results
- **Graph traversal** — Follows branches and connections in both linear and graph mode workflows
- **Variable interpolation** — `{{variable}}` syntax resolved at runtime
- **Sub-flow execution** — Spawns child scenarios for sub-flow steps, resuming the parent on completion
- **Safety limits** — Iteration cap (1,000), execution timeout (30s), and nested condition depth limit to prevent infinite loops

### Collaboration & Real-Time
- **Action Cable presence** — See who is editing a workflow in real time via `WorkflowChannel`
- **Optimistic locking** — Prevents conflicting saves with automatic conflict detection

### Organization
- **Hierarchical groups** — Nested groups (up to 5 levels) with recursive membership
- **Folders** — Organize workflows within groups with drag-and-drop reordering
- **Template library** — Save and reuse workflows as templates; admin-managed public templates
- **Search and filtering** — Client-side fuzzy search (Fuse.js) across workflows

### Import & Export
- **Import** from JSON, CSV, YAML, or Markdown — auto-detects format, assigns UUIDs, marks incomplete steps
- **Export** to JSON or PDF (Prawn) with full step details

### Access Control
- **Three roles** — Administrator, Editor, User with granular permissions
- **Group-based visibility** — Workflows inherit access from group membership; parent groups cascade to children
- **Account security** — Devise authentication with lockable accounts, rate limiting (Rack::Attack)

### Admin Panel (`/admin`)
- User management with role assignment, password resets, and bulk group assignment
- Template management (create, edit, categorize)
- Group and folder hierarchy management
- Workflow overview and monitoring

### Guided Workflow Wizard
- **Three-step creation wizard** — Title/description, add steps with templates, review and publish
- **Step templates** — Pre-built step configurations for common patterns
- **Live flow preview** — Visual preview updates as you build

## Tech Stack

| Layer | Technology |
|-------|-----------|
| **Framework** | Ruby on Rails 8.1 (#nobuild — no Node.js required) |
| **Frontend** | Hotwire (Turbo + Stimulus), 66 Stimulus controllers |
| **Styling** | Vanilla CSS (@layer cascade, OKLCH design tokens, Propshaft) |
| **Database** | SQLite (dev/test), PostgreSQL (production) |
| **Real-time** | Action Cable (Redis in production, in-memory in dev) |
| **Auth** | Devise with lockable accounts |
| **PDF** | Prawn |
| **Rich Text** | Action Text + Lexxy (Lexical-based editor) |
| **JS (vendored)** | SortableJS, Fuse.js, dagre, leader-line, spark-md5 |
| **Monitoring** | Sentry (sentry-rails) |
| **Security** | Rack::Attack, Brakeman, Bullet (N+1 detection) |
| **Linting** | RuboCop (with rails, minitest, performance plugins) |
| **Deployment** | Kamal, Puma |

## Prerequisites

- Ruby 4.0.0+
- Bundler
- SQLite3 (development) or PostgreSQL (production)

No Node.js required — uses Rails' importmap-rails for JS and Propshaft for vanilla CSS (no build step).

## Installation

```bash
git clone https://github.com/ScribeK2/TurboFlows
cd TurboFlows
bundle install

# Setup database
rails db:create db:migrate db:seed

# Start development server
bin/dev
```

Visit `http://localhost:3000` to access the application.

## Usage

1. **Sign up** with email and password
2. **Create a workflow** from scratch, use the guided wizard, or start from a template
3. **Add steps** — questions, actions, sub-flows, messages, escalations, or resolve steps
4. **Switch to Graph Mode** for visual node-based editing with connections
5. **Test** with Scenario Mode — walk through the flow step by step
6. **Organize** into groups and folders
7. **Export** as JSON or PDF, or save as a reusable template

## Running Tests

```bash
# All tests (Minitest)
bin/rails test

# Single file
bin/rails test test/models/workflow_test.rb

# Specific test by line number
bin/rails test test/models/workflow_test.rb:42

# Verbose output
bin/rails test -v
```

## Deployment

Configured for deployment with [Kamal](https://kamal-deploy.org/). See `config/deploy.yml` for details.

Required environment variables:
- `RAILS_MASTER_KEY`
- `SECRET_KEY_BASE`
- PostgreSQL credentials

## Contributing

Contributions welcome. Please follow Rails conventions, add Minitest tests for new features, and ensure all tests pass before submitting.

## License

MIT License — see [LICENSE](LICENSE) for details.
