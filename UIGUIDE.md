# UIGUIDE.md — TurboFlows Visual Design Guide

> **Audience:** LLM agents and developers generating new views for TurboFlows.
> Read this file before creating or modifying any view template.
> For token values, read `app/assets/stylesheets/_global.css`.
> For coding conventions, read `STYLE.md`. For architecture, read `AGENTS.md`.
>
> **Maintenance:** When modifying CSS component files, verify UIGUIDE.md references
> are still accurate. See the maintenance rule in STYLE.md.
>
> **Conflict rule:** When existing views use patterns that contradict this guide
> (inline styles, utility-only layout, hardcoded colors), follow THIS GUIDE for
> new code. Do not copy legacy patterns from existing views.

---

## Section 1: Design Philosophy

### Aesthetic Identity — "Calm + Fizzy"

TurboFlows uses a dual-energy aesthetic:
- **Calm** — low-contrast, blue-tinted neutral surfaces. The canvas breathes. Generous whitespace. No visual noise.
- **Fizzy** — saturated OKLCH accent pops on interactive elements. Buttons, badges, and step-type indicators use vivid color to draw attention where it matters.

The result: a quiet, professional workspace where the important things (actions, decisions, alerts) pop against a calm background. Think Basecamp/HEY energy, not Material Design density.

### Color Model — OKLCH

All colors use OKLCH (Oklch Lightness Chroma Hue). Never hardcode hex, rgb, or hsl values.

**Key token names** (values in `_global.css`):
- Canvas: `var(--color-canvas)`, `var(--color-canvas-alt)`, `var(--color-canvas-raised)`
- Ink: `var(--color-ink)`, `var(--color-ink-subtle)`, `var(--color-ink-muted)`
- Borders: `var(--color-border)`, `var(--color-border-strong)`
- Primary accent: `var(--color-primary)`, `var(--color-primary-hover)`, `var(--color-primary-soft)`
- Semantic: `var(--color-negative)`, `var(--color-positive)`, `var(--color-warning)`

**Step-type hues** — each step type has a dedicated hue token:
- `var(--hue-question)` (250, blue), `var(--hue-action)` (145, green)
- `var(--hue-message)` (290, purple), `var(--hue-escalate)` (25, red/orange)
- `var(--hue-resolve)` (160, teal), `var(--hue-subflow)` (310, magenta)

### Typography

System fonts only. No web fonts, no Google Fonts.
- Body: `var(--font-sans)` — system-ui stack
- Code: `var(--font-mono)` — ui-monospace stack
- Scale: `var(--text-xs)` through `var(--text-4xl)`
- Weights: 400 (body), 500 (labels, buttons), 600 (subheadings), 700 (headings)
- Line heights: `var(--line-height-tight)` 1.25, `var(--line-height-normal)` 1.5, `var(--line-height-relaxed)` 1.75

### Spacing

Use the `--space-N` scale. Never use raw rem/px values for spacing.
- Tight: `var(--space-1)` 0.25rem, `var(--space-2)` 0.5rem
- Standard: `var(--space-3)` 0.75rem, `var(--space-4)` 1rem
- Generous: `var(--space-6)` 1.5rem, `var(--space-8)` 2rem
- Section: `var(--space-12)` 3rem, `var(--space-16)` 4rem

### Shadows

Dual-layer shadows for depth. Use token names, never write raw box-shadow values.
- `var(--shadow-sm)` — cards, inputs (subtle lift)
- `var(--shadow)` — dropdowns, popovers (medium lift)
- `var(--shadow-lg)` — dialogs, modals (high lift)
- `var(--shadow-xl)` — tooltips, floating elements

### Border Radii

- `var(--radius-sm)` 0.25rem — pills, small badges
- `var(--radius)` 0.5rem — general purpose
- `var(--radius-md)` 0.625rem — buttons, inputs (interactive elements)
- `var(--radius-lg)` 0.75rem — cards
- `var(--radius-xl)` 1rem — large containers
- `var(--radius-full)` 9999px — avatars, dots

### Motion

Transitions are subtle and purposeful. Spring easing for interactive feedback.
- `var(--duration-snap)` 120ms — toggles, checkboxes
- `var(--duration-fast)` 150ms — buttons, hovers
- `var(--duration-normal)` 250ms — panels, slides
- `var(--duration-slow)` 400ms — page transitions
- Easing: `var(--ease-out)`, `var(--ease-in-out)`, `var(--ease-spring)` (bouncy)

### Dark Mode

Dark mode is automatic. Use token names and they swap values via `[data-theme="dark"]` and `@media (prefers-color-scheme: dark)` in `_global.css`. **Do not write separate dark mode CSS.** If you use tokens correctly, dark mode works for free.

### Anti-Patterns — What TurboFlows is NOT

- **No Tailwind classes** — use component classes (`.btn--primary`) or utility classes from `utilities.css`
- **No hardcoded colors** — always `var(--color-*)` or `var(--hue-*)` tokens
- **No inline `style=""` attributes** — use component/utility classes instead
- **No gradients on surfaces** — only buttons get subtle gradients (`.btn--primary`)
- **No heavy shadows** — max is `var(--shadow-xl)`, and that's rare
- **No external fonts or CDN links** — system fonts only
- **No raw px/rem for spacing** — use `var(--space-N)` tokens

---

## Section 2: Component Catalog

Each component references its CSS file by selector name. Read that file for exact values.

### Buttons (`buttons.css`)

| Class | Use when | Visual |
|-------|----------|--------|
| `.btn` | Base button (transparent bg, border) | Inline-flex, 1.5px border, radius-md |
| `.btn--primary` | Primary action (submit, save, create) | Blue gradient bg, white text, shadow |
| `.btn--secondary` | Secondary action (edit, cancel) | Canvas-alt bg, ink text |
| `.btn--ghost` | Tertiary/inline action | Transparent, text only, hover shows bg |
| `.btn--plain` | Minimal button (filters, pagination) | No border, subtle hover |
| `.btn--danger` | Destructive action (delete, remove) | Red/negative color accent |
| `.btn--positive` | Completion action (resolve, complete) | Green/positive color accent |
| `.btn--sm` | Compact size modifier | Smaller padding, text-xs |

**Active state:** All buttons scale to 0.96 on press (`transform: scale(0.96)`).
**Stimulus:** Buttons with confirm dialogs use `data-turbo-confirm`.

### Cards (`cards.css`)

| Class | Use when | Visual |
|-------|----------|--------|
| `.card` | Any contained content block | White bg, border, radius-lg, shadow-sm |
| `.card--bordered-top` | Step-type colored cards | 3.5px colored top border + gradient glow |
| `.card--question` `.card--action` etc. | Step type specific | Top border color from `--hue-*` token |
| `.card--accent-left` | Left-accent emphasis | 3px left border |
| `.card--muted` | De-emphasized content | Canvas-alt bg, no shadow |
| `.card__body` | Card content area | Standard padding |

### Forms (`forms.css`)

| Class | Use when | Visual |
|-------|----------|--------|
| `.form-group` | Wraps label + input pair | Flex column, gap, margin-bottom |
| `.form-label` | Input label | text-sm, weight 500 |
| `.form-label.is-required` | Required field | Appends red " *" |
| `.form-input` | Text inputs, textareas | Canvas-alt bg, 1.5px border, inset shadow |
| `.form-select` | Select dropdowns | Same as form-input + arrow |
| `.form-hint` | Help text below input | text-xs, muted color |

**Focus:** Inputs get `var(--focus-ring)` (2px solid primary) on `:focus-visible`.
**Stimulus:** Forms with autosave use `data-controller="inline-autosave"`.

### Dialogs (`dialogs.css`)

| Class | Use when | Visual |
|-------|----------|--------|
| `.dialog-overlay` | Modal backdrop | Fixed, black 40% opacity, blur |
| `.dialog` | Modal container | Centered, white bg, shadow-xl, radius-xl |
| `.dialog--sm` | Small modal (confirm) | max-width 28rem |
| `.dialog--lg` | Large modal (forms) | max-width 48rem |
| `.dialog__header` | Title bar | Flex, border-bottom |
| `.dialog__body` | Content area | Padding, overflow-y auto |
| `.dialog__footer` | Action buttons | Flex end, gap, border-top |

**Stimulus:** `data-controller="dialog"` for open/close. `data-controller="dialog-manager"` on body for single-open enforcement.

### Dropdowns (`dropdowns.css`)

| Class | Use when | Visual |
|-------|----------|--------|
| `.dropdown` | Dropdown container | Relative positioning |
| `.dropdown__menu` | Popup menu | Absolute, white bg, shadow, radius |
| `.dropdown__item` | Menu option | Padding, hover bg change |
| `.dropdown__header` | Section label in menu | Uppercase, muted, text-xs |
| `.dropdown__divider` | Separator line | 1px border |

**Stimulus:** `data-controller="dropdown"` for toggle behavior.

### Tables (`tables.css`)

| Class | Use when | Visual |
|-------|----------|--------|
| `.table-wrap` | Responsive container | overflow-x auto, touch scrolling |
| `.table` | Data table | Full width, border-collapse |
| `.table th` | Header cells | Uppercase, text-xs, weight 600, muted |
| `.table td` | Data cells | Padding, border-bottom |
| `.table tr:hover` | Row hover | Subtle canvas-alt background |

### Badges (`badges.css`)

| Class | Use when | Visual |
|-------|----------|--------|
| `.badge` | Generic label | Inline-flex, text-xs, radius-full, pill shape |
| `.badge--question` through `.badge--sub-flow` | Step type | Color from `--hue-*` token |
| `.badge--draft` `.badge--published` | Workflow status | Yellow/green tint |
| `.badge--admin` `.badge--editor` `.badge--regular` | User role | Role-specific color |
| `.badge--alert` | Error/urgent | Red/negative tint |
| `.badge--warning` | Warning | Yellow/warning tint |
| `.badge--info` | Informational | Blue/primary tint |

### Flash Messages (`flash.css`)

| Class | Use when | Visual |
|-------|----------|--------|
| `.flash` | Notification bar | Fixed top-right, slide-in animation |
| `.flash--notice` | Success/info message | Green/positive accent |
| `.flash--alert` | Error message | Red/negative accent |
| `.toast` | Toast notification | Fixed bottom-right, smaller |

### Navigation (`navigation.css`)

| Class | Use when | Visual |
|-------|----------|--------|
| `.page-header` | Top nav bar | Fixed top, white bg, border-bottom, z-nav |
| `.page-header__inner` | Max-width container | 80rem max, padding-inline |
| `.page-header__row` | Three-zone grid | `grid-template-columns: 1fr auto 1fr` |

**Structure:** Left zone (search), center (logo), right (actions). Height: 4rem.
**Stimulus:** `data-controller="nav-search"` for Cmd+K search, `data-controller="nav-menu"` for menu dropdown.

### Other Components

| Component | Classes | File | Notes |
|-----------|---------|------|-------|
| Tooltips | `.tooltip`, `.tooltip--bottom` | `tooltips.css` | Absolute, spring easing entrance |
| Skeletons | `.skeleton`, `.skeleton--text`, `--heading`, `--card` | `skeleton.css` | Shimmer animation, use for loading states |
| Pagination | `.pagination`, `.pagination__item`, `.is-active` | `pagination.css` | Flex row, min-width 2rem items |
| Icons | `.icon`, `.icon--xs/sm/lg/xl` | `icons.css` | Inline-flex sizing (0.75 to 2rem) |

### Empty States

Use a centered card layout with an icon, heading, description, and optional CTA button:

```html
<div class="card" style="padding: var(--space-8); text-align: center;">
  <svg class="icon icon--xl mx-auto mb-4">...</svg>
  <h3 class="font-semibold mb-2">No items found</h3>
  <p class="text-sm" style="color: var(--color-ink-muted);">Description text here.</p>
  <div class="mt-4">
    <a href="..." class="btn btn--primary btn--sm">Create New</a>
  </div>
</div>
```

### Error/Validation States

- **Inline field errors:** Add `.is-invalid` to `.form-input` and display error text in a `<span class="form-error">` below the input.
- **Flash errors:** Use `.flash--alert` for page-level errors.
- **Toast errors:** Use `.toast--error` for async operation failures.

### Utility Classes vs. Component Classes

Use **component classes** for what things ARE: `.btn--primary`, `.card`, `.form-input`.
Use **utility classes** (from `utilities.css`) for layout glue: `.flex`, `.items-center`, `.gap-3`, `.mb-4`, `.text-sm`, `.font-semibold`.

Rule: if you're describing a component's identity, use a component class. If you're adjusting spacing or layout between components, use a utility class.

### Common Stimulus Controllers

These are the most-used controllers. Wire them via `data-controller` on the appropriate element.

| Controller | Purpose | Common data-actions |
|-----------|---------|-------------------|
| `inline-autosave` | Debounced form autosave (2s) | Listens for `input`, `change`, `lexxy:change` |
| `dialog` | Open/close modals | `click->dialog#open`, `click->dialog#close` |
| `dialog-manager` | Single-open enforcement | Place on `<body>` |
| `dropdown` | Toggle dropdown menus | `click->dropdown#toggle` |
| `clipboard` | Copy text to clipboard | `click->clipboard#copy` |
| `tooltip` | Show/hide tooltips | `mouseenter->tooltip#show`, `mouseleave->tooltip#hide` |
| `nav-search` | Cmd+K fuzzy search | On search input |
| `scenario-step` | Player step interactions | On step card, handles auto-advance |
| `tabs` | Tab switching | `click->tabs#select` |

---

## Section 3: Page Recipes

Each recipe shows the complete HTML structure for a page type. Use these as starting points for new views.

### Recipe 1: Dashboard / Index Page

Two-column layout with sidebar and card-based content list.

```erb
<div class="page-content">
  <!-- Page Header -->
  <div class="page-header-section">
    <div>
      <h1 class="page-header-section__title">Page Title</h1>
      <p class="page-header-section__subtitle">Optional subtitle text</p>
    </div>
    <div class="flex items-center gap-2">
      <%= link_to new_thing_path, class: "btn btn--primary btn--sm" do %>
        <svg class="icon icon--sm">...</svg>
        New Item
      <% end %>
    </div>
  </div>

  <!-- Content Area -->
  <div class="card">
    <ul>
      <%% @items.each do |item| %>
        <li class="flex items-center justify-between"
            style="padding: var(--space-3) var(--space-4); border-bottom: 1px solid var(--color-border);">
          <div>
            <h3 class="font-semibold"><%= item.title %></h3>
            <p class="text-sm" style="color: var(--color-ink-subtle);"><%= item.description %></p>
          </div>
          <div class="flex items-center gap-2">
            <span class="badge"><%= item.status %></span>
            <%= link_to "View", item_path(item), class: "btn btn--plain btn--sm" %>
          </div>
        </li>
      <%% end %>
    </ul>
  </div>

  <!-- Empty State (when no items) -->
  <%% if @items.empty? %>
    <div class="card" style="padding: var(--space-8); text-align: center;">
      <svg class="icon icon--xl mx-auto mb-4">...</svg>
      <h3 class="font-semibold mb-2">No items yet</h3>
      <p class="text-sm" style="color: var(--color-ink-muted);">Get started by creating your first item.</p>
    </div>
  <%% end %>
</div>
```

**Layout:** `.page-content` wraps everything. `.page-header-section` is a flex row (title left, actions right). Content goes in `.card` containers.

### Recipe 2: Detail / Show Page

Single-column content with a header and sections.

```erb
<div class="page-content">
  <div class="page-main">
    <!-- Breadcrumb + Back -->
    <nav class="mb-4">
      <%= link_to "← Back to list", items_path, class: "btn btn--plain btn--sm" %>
    </nav>

    <!-- Header -->
    <div class="page-header-section">
      <div>
        <h1 class="page-header-section__title"><%= @item.title %></h1>
        <div class="flex items-center gap-2 mt-1">
          <span class="badge badge--<%= @item.status %>"><%= @item.status.titleize %></span>
          <span class="text-sm" style="color: var(--color-ink-muted);">
            Updated <%= time_ago_in_words(@item.updated_at) %> ago
          </span>
        </div>
      </div>
      <div class="flex items-center gap-2">
        <%= link_to edit_item_path(@item), class: "btn btn--secondary btn--sm" do %>Edit<% end %>
      </div>
    </div>

    <!-- Content Sections -->
    <div class="card mb-4">
      <div class="card__body">
        <h2 class="font-semibold mb-3" style="font-size: var(--text-lg);">Details</h2>
        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: var(--space-4);">
          <div>
            <dt class="form-label">Field Name</dt>
            <dd class="text-sm"><%= @item.field_value %></dd>
          </div>
        </div>
      </div>
    </div>
  </div>
</div>
```

**Layout:** `.page-main` provides max-width (80rem) and responsive padding. Cards stack vertically with `.mb-4` spacing.

### Recipe 3: Form Page

Full form with grouped fields, validation, and submit actions.

```erb
<div class="page-content">
  <div class="page-main">
    <div class="page-header-section">
      <h1 class="page-header-section__title">Create New Item</h1>
    </div>

    <div class="card">
      <div class="card__body">
        <%= form_with model: @item, class: "space-y-4",
            data: { controller: "inline-autosave" } do |f| %>

          <div class="form-group">
            <%= f.label :title, class: "form-label is-required" %>
            <%= f.text_field :title, class: "form-input", required: true,
                placeholder: "Enter title..." %>
          </div>

          <div class="form-group">
            <%= f.label :description, class: "form-label" %>
            <%= f.text_area :description, class: "form-input", rows: 4,
                placeholder: "Optional description..." %>
          </div>

          <div class="form-group">
            <%= f.label :category, class: "form-label" %>
            <%= f.select :category, options_for_select(categories),
                { prompt: "Select..." }, class: "form-select" %>
          </div>

          <!-- Form Actions -->
          <div class="flex items-center justify-end gap-3"
               style="padding-top: var(--space-4); border-top: 1px solid var(--color-border);">
            <%= link_to "Cancel", items_path, class: "btn btn--plain" %>
            <%= f.submit "Create Item", class: "btn btn--primary" %>
          </div>
        <%% end %>
      </div>
    </div>
  </div>
</div>
```

**Pattern:** `.form-group` wraps each label+input pair. `.space-y-4` utility adds vertical spacing between groups. Submit actions right-aligned with border-top separator.

### Recipe 4: Settings / Admin Page

Sectioned layout with toggles, descriptions, and action buttons.

```erb
<div class="page-content">
  <div class="page-main">
    <div class="page-header-section">
      <h1 class="page-header-section__title">Settings</h1>
      <p class="page-header-section__subtitle">Manage your preferences</p>
    </div>

    <!-- Settings Section -->
    <div class="card mb-4">
      <div class="card__body">
        <h2 class="font-semibold mb-1" style="font-size: var(--text-lg);">General</h2>
        <p class="text-sm mb-4" style="color: var(--color-ink-muted);">Basic configuration options</p>

        <div style="display: flex; flex-direction: column; gap: var(--space-4);">
          <!-- Setting Row -->
          <div class="flex items-center justify-between"
               style="padding: var(--space-3) 0; border-bottom: 1px solid var(--color-border);">
            <div>
              <h3 class="font-semibold text-sm">Setting Name</h3>
              <p class="text-xs" style="color: var(--color-ink-muted);">Description of what this setting controls.</p>
            </div>
            <div>
              <!-- Toggle, button, or input goes here -->
              <button class="btn btn--secondary btn--sm">Configure</button>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- Danger Zone -->
    <div class="card" style="border-color: var(--color-negative);">
      <div class="card__body">
        <h2 class="font-semibold mb-1" style="font-size: var(--text-lg); color: var(--color-negative);">
          Danger Zone
        </h2>
        <div class="flex items-center justify-between mt-3">
          <p class="text-sm">Permanently delete this item and all its data.</p>
          <button class="btn btn--danger btn--sm">Delete</button>
        </div>
      </div>
    </div>
  </div>
</div>
```

**Pattern:** Each settings section is a `.card` with a heading, description, and setting rows. Danger zone card uses `border-color: var(--color-negative)` for visual warning.

### Recipe 5: Player Page (Lightweight Skeleton)

Player pages use a **separate layout** (`layouts/player.html.erb`) and **separate CSS** (`_player.css`). Do not use the main application layout.

```erb
<%% content_for(:title) { "Workflow Title — TurboFlows Player" } %>

<!-- Progress bar -->
<div class="player-progress">
  <div class="player-progress__bar">
    <div class="player-progress__fill" style="width: 40%"></div>
  </div>
  <div class="player-progress__text">Step 2 of 5</div>
</div>

<!-- Step Card -->
<div class="card player-step-card" data-controller="scenario-step">
  <div class="card__body">
    <!-- Step header, content, and form go here -->
    <!-- See app/views/player/step.html.erb for full implementation -->
  </div>
</div>
```

**Key files:** `app/views/layouts/player.html.erb`, `app/assets/stylesheets/_player.css`, `app/controllers/player_controller.rb`.

### Golden Examples

For page types not covered by a recipe, read these exemplary views. They demonstrate correct page structure and component usage.

> **Note:** These views may contain some legacy utility classes or inline styles
> from before the semantic CSS migration. Follow THIS GUIDE for new code patterns.
> Use these examples for structural reference (page layout, component composition,
> data flow), not as CSS pattern templates.

| View file | Page type | Good for |
|-----------|-----------|----------|
| `app/views/workflows/index.html.erb` | Index/list with sidebar | Two-column layout, search, filters, pagination, empty state |
| `app/views/player/step.html.erb` | Step execution | Card-based UI, form variations, button bars, progress stepper |
| `app/views/workflows/_builder.html.erb` | Builder/editor | Header with inline edit, panel system, toolbar, Stimulus wiring |

---

## Section 4: Quick Reference

### CSS File Map

| File | Layer | What it contains |
|------|-------|-----------------|
| `application.css` | (layer order) | `@layer reset, base, components, modules, utilities;` |
| `reset.css` | reset | Browser reset |
| `base.css` | base | Base element styles (body, links, headings) |
| `_global.css` | base | **All design tokens** (colors, spacing, typography, shadows, radii, motion) |
| `buttons.css` | components | Button variants |
| `cards.css` | components | Card variants |
| `forms.css` | components | Form controls |
| `dialogs.css` | components | Modal dialogs |
| `dropdowns.css` | components | Dropdown menus |
| `tables.css` | components | Data tables |
| `badges.css` | components | Badges, pills, dots |
| `flash.css` | components | Flash messages, toasts |
| `icons.css` | components | Icon sizing |
| `tooltips.css` | components | Tooltip positioning |
| `skeleton.css` | components | Loading skeletons |
| `pagination.css` | components | Page navigation |
| `_tags.css` | components | Tag pills, autocomplete |
| `_player.css` | components | Player-specific styles |
| `_form_step.css` | components | FormStep builder UI |
| `_media.css` | components | Media attachments |
| `_version_diff.css` | components | Version comparison |
| `navigation.css` | modules | Top nav bar |
| `layout.css` | modules | Page structure (.page-body, .page-main) |
| `builder.css` | components | Builder-specific styles |
| `workflows.css` | modules | Workflow list/show styles |
| `scenarios.css` | modules | Scenario execution styles |
| `steps.css` | modules | Step editor styles |
| `editor.css` | modules | Rich text editor (Lexxy) |
| `transitions.css` | modules | Transition editor |
| `dashboard.css` | modules | Dashboard layout |
| `auth.css` | modules | Login/signup pages |
| `admin.css` | modules | Admin panel |
| `utilities.css` | utilities | Layout utilities (.flex, .gap-*, .mb-*, .text-*) |
| `animations.css` | utilities | Keyframes (fadeIn, slideIn, scaleIn, shimmer) |
| `print.css` | utilities | Print styles |

### @layer Order

```
@layer reset, base, components, modules, utilities;
```

- **reset** — browser normalization
- **base** — element defaults + design tokens
- **components** — reusable UI pieces (buttons, cards, forms, badges)
- **modules** — page-specific compositions (builder, scenarios, navigation)
- **utilities** — layout helpers, overrides (highest specificity in cascade)

### Class Naming Convention

TurboFlows uses a BEM-inspired convention:
- **Block:** `.card`, `.btn`, `.dialog`, `.form-input`
- **Modifier:** `.card--bordered-top`, `.btn--primary`, `.badge--question`
- **Element:** `.card__body`, `.dialog__header`, `.page-header__row`

Element sub-classes (`__`) are used sparingly, only where HTML structure is stable. The primary pattern is block + double-dash modifier.

**State classes** use `.is-*` prefix: `.is-hidden`, `.is-active`, `.is-disabled`, `.is-invalid`, `.is-dragover`.

### Pre-Submit Checklist

Before submitting a new or modified view, verify:

1. **No Tailwind utility classes** — use component classes or classes defined in `utilities.css`
2. **No hardcoded hex/rgb/oklch values** — use `var(--token-name)` from `_global.css`
3. **Correct @layer declaration** — new CSS goes in the right layer (reset/base/components/modules/utilities)
4. **Component classes match catalog** — e.g., `.btn--primary`, not `.button-blue`
5. **Stimulus data-controller attributes wired** for interactive elements
6. **Works in both light and dark mode** — tokens auto-swap, no manual overrides needed
7. **Responsive** — tested at mobile (< 640px), tablet (640-1024px), desktop (1024px+)
8. **Spacing uses --space-N tokens** — no raw rem/px values for margins/padding/gaps
