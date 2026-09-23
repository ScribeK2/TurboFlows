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

### Aesthetic Identity — "Calm + Deliberate"

TurboFlows uses a near-monochrome navy system:
- **Calm** — low-chroma, blue-tinted neutral surfaces. Flat. Hairline 1px borders do the work that shadows used to. Generous whitespace.
- **Deliberate** — color is *scarce*, and scarcity is the point. One filled button per screen. A pill only for step types and genuinely exceptional states. Everything else reads as quiet text.

The result: a page where the eye lands on the one thing that matters, because it is the only saturated element present. Corporate and composed, not playful.

**Scarcity rules (these carry most of the look):**
1. **One filled button per screen.** Everything else is `.btn--secondary` (outlined) or `.btn--plain` (text).
2. **Pills only for exceptions.** Ordinary status ("Published") is plain text; a pill means "look here" (e.g. a failure).
3. **Mint appears once or not at all.** It marks terminal completion only.

### Color Model — OKLCH

All colors use OKLCH (Oklch Lightness Chroma Hue). Never hardcode hex, rgb, or hsl values.

**Key token names** (values in `_global.css`):
- Canvas: `var(--color-canvas)`, `var(--color-canvas-alt)`, `var(--color-canvas-raised)`
- Ink: `var(--color-ink)`, `var(--color-ink-subtle)`, `var(--color-ink-muted)`
- Borders: `var(--color-border)`, `var(--color-border-strong)`
- Primary: `var(--color-primary)` (fills), `var(--color-primary-text)` (links/icons on canvas), `var(--color-primary-hover)` (a filled button's hover), `var(--color-primary-text-hover)` (a link's hover), `var(--color-primary-soft)`, `var(--color-primary-muted)`
- Avatars: `var(--color-avatar-admin)`, `var(--color-avatar-regular)` — theme-independent fills under a literal white initial
- Mint: `var(--color-mint)` — **terminal completion only** (Resolve step, scenario complete)
- Semantic, two tiers: `var(--color-negative)` / `var(--color-negative-soft)`, same for `positive` and `warning`

**Two-tier semantics — pick by role, not by vibe:**
- `--color-X` is sized for **text, icons and borders**.
- `--color-X-soft` is the **pill fill**.
- `--color-on-X` is text that sits **on top of** a `--color-X` fill.

> Never put white text on `--color-negative/positive/warning`. In dark mode those
> tokens are *light* fills (L 0.80) because they are sized for text, so white on
> them measures ~3:1 and fails AA. Use `var(--color-on-negative)` etc., which is
> white in light and ink in dark.

**Why `--color-primary-text` exists:** in dark mode a fill carrying white text has
to be dark enough for 4.5:1, and a link on the canvas has to be light enough for
the same. No single lightness does both, so fill and text are separate tokens —
and so are their hovers: `--color-primary-hover` *darkens* a filled button,
`--color-primary-text-hover` *lightens* a link. In light mode each pair aliases
the same navy.

These ratios are measured from the token values by
`test/stylesheets/token_contrast_test.rb`. Until 2026-09-10 the dark fill sat at
L 0.70 beside a comment reading "fill, white text", at 2.68:1, and this paragraph
said the split "lets each sit comfortably". A comment describes an intent; only a
measurement says whether the value meets it.

**Step-type hues** — each step type has a dedicated hue token. Step colour is
**pale tints only**, and appears only on badges, flow-diagram nodes and dots —
never as a card border or row background (surfaces stay neutral):
- `var(--hue-question)` (250, blue), `var(--hue-action)` (145, green)
- `var(--hue-message)` (290, purple), `var(--hue-escalate)` (25, red/orange)
- `var(--hue-resolve)` (160, teal), `var(--hue-subflow)` (310, magenta)
- `var(--hue-form)` (45, amber/yellow)

**How to use a step hue.** Set `--step-hue` on the element, then consume the
composed token — never write `oklch()` inline:

```css
.badge--question { --step-hue: var(--hue-question); }
.badge--question { background: var(--step-bg); color: var(--step-text); }
```

Available: `--step-bg` (pale fill), `--step-text` (text on that fill),
`--step-border`, `--step-dot` (dots, diagram nodes), `--step-solid` (filled chip)
with `--step-on-solid` for its text. All five swap per theme automatically.

> **The trap this replaced:** these are composed in a `*` rule, NOT on `:root`.
> A custom property whose value contains `var()` resolves at the element where it
> is *declared*. Declared on `:root`, `--step-bg` resolves against `:root`'s
> undefined `--step-hue`, becomes invalid, and inherits as invalid — descendants
> setting `--step-hue` never re-resolve it. The L/C values live on `:root` as
> plain scalars (`--step-bg-l`, `--step-bg-c`); the `*` rule composes them
> per-element. **Never declare an inherited custom property containing a `var()`
> that points at something descendants will set.**

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

Surfaces are **flat**. Cards and inputs use a 1px hairline border, not a shadow;
`--shadow-sm` is deliberately `none`. Shadows survive only for elements that
genuinely float above the page. Use token names, never raw box-shadow values.
- `var(--shadow-sm)` — none (kept so existing rules stay valid)
- `var(--shadow)` — dropdowns, popovers (medium lift)
- `var(--shadow-lg)` — dialogs, modals (high lift)
- `var(--shadow-xl)` — floating elements

### Border Radii

- `var(--radius-sm)` 0.25rem — small badges
- `var(--radius)` 0.375rem — general purpose
- `var(--radius-md)` 0.375rem — buttons, inputs (interactive elements)
- `var(--radius-lg)` 0.5rem — cards
- `var(--radius-xl)` 0.75rem — large containers
- `var(--radius-full)` 9999px — avatars, dots

### Motion

Transitions are subtle and purposeful. Spring easing for interactive feedback.
- `var(--duration-snap)` 120ms — toggles, checkboxes
- `var(--duration-fast)` 150ms — buttons, hovers
- `var(--duration-normal)` 250ms — panels, slides
- `var(--duration-slow)` 400ms — page transitions
- Easing: `var(--ease-out)`, `var(--ease-in-out)`, `var(--ease-spring)` (bouncy)

**No entrance animations on pages people return to.** Turbo renders a cached copy
of a page as a preview, then swaps in the fresh one. A `fadeIn`/`fadeInUp` on the
page starts on the preview and restarts ~360ms later on the swap, mid-flight, and
the Back button replays it every time. That was the dashboard's "jittery load".
So both dashboards (`dashboard/home` and `dashboard/csr`) carry no `animate-*`
class, render `<meta name="turbo-cache-control" content="no-preview">`, and load
nothing after render. A new page people return to should follow the same rule.
`test/integration/dashboard_motion_test.rb` guards both dashboards.
The `animations.css` utilities remain for one-shot surfaces.

### Dark Mode

Dark mode is automatic. Use token names and they swap values via `[data-theme="dark"]` and `@media (prefers-color-scheme: dark)` in `_global.css`. **Do not write separate dark mode CSS.** If you use tokens correctly, dark mode works for free.

### Anti-Patterns — What TurboFlows is NOT

- **No Tailwind classes** — use component classes (`.btn--primary`) or utility classes from `utilities.css`
- **No hardcoded colors** — always `var(--color-*)` or `var(--hue-*)` tokens
- **No *literal* colour in an inline `style=""`** — the hardcoded-colour rule
  above applies inside style attributes too, so `background: rgba(0,0,0,.5)`
  is out and `background: var(--color-canvas)` is fine. Inline `style=""`
  itself is not banned: for a one-off layout value (a grid template, a fixed
  position) it is the right tool, and the recipes in Section 3 use it
- **No gradients anywhere** — not on surfaces, not on buttons
- **No shadows on cards, rows or inputs** — a 1px hairline border is the separator. Shadows are for popovers, dropdowns and dialogs only
- **No second filled button** on the same screen
- **No colored borders or tinted backgrounds to signal step type** — that lives in the badge
- **No `oklch()` written inline against `--step-hue`** — use `--step-bg` / `--step-text` / `--step-dot` / `--step-solid`
- **No external fonts or CDN links** — system fonts only
- **No raw px/rem for spacing** — use `var(--space-N)` tokens

### The unstyled-button trap

`reset.css` neutralises `background`, `border` and `padding` on every `<button>`
(and `input[type=submit|button]`), not just `font` and `color`. Without that, a
button whose class forgot a fill and a border rendered as the browser's own
chrome — grey ButtonFace, outset bevel, square corners.

**Why it kept shipping:** the markup looks fine, and in light mode
`rgb(239, 239, 239)` hides against a pale surface. Only in dark mode, where the
UA value stays light while the tokens go dark, does it read obviously wrong. It
landed three times — `.file-dropzone`, `.dark-mode-toggle`, then
`.scenario-exec-toggle` and `.wf-status-tabs__tab` together. The last of those
made the Analytics filter segments read *inverted* in dark mode: the unselected
ones were light blocks, the selected one dark.

**What this does and does not buy you.** The reset is a floor, so a forgotten
declaration is no longer catastrophic. It is not a substitute for saying what an
element looks like: declare a component's resting `background` in its own rule.
`.wf-status-tabs__tab` is the cautionary case — it set a background only in its
`.is-active` variant, so it rendered correctly as an `<a>` and wrong as a
`<button>`, from one missing line.

`test/integration/button_chrome_reset_test.rb` guards both halves.

### Surfaces Deliberately Excluded

Some surfaces were left out of the northwest-palette migration on purpose. They
are **not** unfinished work, and tidying them into line with the rest of the
system is a change of design, not a cascade fix. Do not restructure one without
meeting its reopen condition.

Entries that have since been migrated are kept here rather than deleted: the
record of *why* a surface was excluded, and what met the condition, is what
stops the next person re-litigating it. One live exclusion remains.

- **Scenario runner mechanics** — *no longer excluded.* This entry used to park
  the radio cards, button bar and progress rail in `scenarios/step` and
  `scenarios/show`, with the reopen condition "reference material for a runner
  exists, or a real user complaint about the runner comes in." A complaint came
  in, and the rationale — that familiarity is worth more than consistency on a
  screen operated under time pressure on live calls — had no one to protect,
  since nobody was using the tool yet. That was the window, and it was taken.

  What the migration found is worth keeping: the exclusion had been reading as
  "leave this alone" when the surface was not a considered design at all. It had
  simply never been migrated — ~40 hand-written `[data-theme="dark"]` blocks,
  literal `oklch()` values, a banned gradient and shadows on cards and inputs.
  Nearly every fix was deleting bespoke code in favour of a catalog component,
  which is the opposite of the "restyling means inventing" objection that
  justified the exclusion. **Both runners** — Scenario and Player — now share
  one set of step-body partials in `app/views/runner/`, so the two cannot drift
  apart again.

- **Answered steps were one-line rows, and are now cards.** Worth recording
  because the row was a *considered* decision that lost to measurement, not an
  oversight. The rationale was that a scanned list pays for height in how much of
  the call stays visible, so a collapsed step got `title → answer` on one line.
  Measured, the difference was 69px against 38px — over a median completed run of
  12 steps, about half a screen. The behaviour the density was protecting had
  never been watched, which is the same "no one to protect" reasoning that lifted
  the scenario-runner exclusion above. What the card buys is weight: an answered
  step is a decision somebody made on a live call, and scrolling back to re-read
  one is a real thing agents do.
  *Reopen when:* a run gets long enough for height to actually cost something —
  around 25 answered steps on current numbers, which only the largest workflows
  can reach. That is the length-management question, still parked.

- **Builder editing internals** — *no longer excluded for the step panel.* This
  entry parked `_panel_edit` and its form surface in `steps.css` with the reopen
  condition "reference material exists, and then as a design consultation rather
  than a refactor." On 2026-09-15 a browser audit met it the way the chrome
  migration had: the rest of TurboFlows is its own reference. What the audit
  found is worth keeping. Several "styling" problems were controls that did not
  work — a pick-one control whose chosen state no rule styled, a file input on a
  form that was never multipart, radio cards that restyled and saved nothing — so
  the pass was fixes first and style second, and every control now goes through
  a catalog component (choice cards, the file dropzone, one attachment list). The
  guard `test/integration/step_panel_autosave_coverage_test.rb` refuses a panel
  control with no autosave action, the failure that had shipped three times.
  Still excluded: `_preview_pane`, and the flow diagram panel with
  `flow_diagram.css`, which are graph rendering.
  *Reopen those when:* reference material for a diagram exists.

  > **`_visual_editor` and `_visual_condition` are no longer on this list —
  > they were deleted 2026-08-29.** Not restyled: *deleted*. Nothing rendered
  > either of them, and `_visual_editor` was still wired to six Stimulus
  > controllers removed back in `f8240c05`. An exclusion protects a surface from
  > being restyled on a whim; it was never a reason to keep unreachable code.
  > Check reachability before assuming an excluded surface is load-bearing.
  > **`transitions.css` was deleted 2026-09-15.** It never belonged on this
  > list — no rule in it was rendered by anything. Its edge and flowchart
  > selectors (`.edge-group`, `.edge-path`, `.flowchart-svg`, `.edge-label`,
  > `.edge-marker`, `.temp-connection`) belonged to the visual editor deleted
  > 2026-08-29 (`fac414d5` added them alongside it; the `cca393f9` cleanup
  > deleted the editor's partials and 31 rule blocks in `editor.css` but missed
  > this whole file). The transition editor's own rules (`.transition-item`,
  > `.condition-sentence`) live in `steps.css` and `workflows.css`, no longer
  > excluded.

  > **Note what is no longer excluded.** The builder's *chrome* — header,
  > toolbar, step list, step rows, empty state, health panel and the shared
  > panel chrome — was migrated after a design consultation established that
  > the rest of TurboFlows is now mature enough to serve as its own reference,
  > which is what this entry's reopen condition asked for. Its colours were
  > tokenised in a separate pass first; an earlier version of this entry wrongly
  > claimed that had already happened, when `builder.css`, `steps.css`,
  > `transitions.css` and `flow_diagram.css` still carried literal
  > `oklch()`/`#fff` values that never swapped in dark mode — flow-diagram nodes
  > read `var(--color-surface, #fff)`, and `--color-surface` is not a token, so
  > they rendered white in dark mode. The entries above remain excluded: this
  > was a narrowing, not a lifting.

  The scenario runner exclusion above is untouched by that work.

---

## Section 2: Component Catalog

Each component references its CSS file by selector name. Read that file for exact values.

### Buttons (`buttons.css`)

| Class | Use when | Visual |
|-------|----------|--------|
| `.btn` | Base button (transparent bg, border) | Inline-flex, 1px hairline border, radius-md |
| `.btn--primary` | **The one** primary action on the screen | Flat navy fill, white text, no gradient |
| `.btn--secondary` | Everything else with a visible edge | Raised bg, hairline border, navy-muted text |
| `.btn--plain` | Tertiary/minimal action | No border, transparent, subtle hover |
| `.btn--negative` | Destructive action (delete, remove) | Outlined red |
| `.btn--negative.btn--solid` | Confirming action inside a destructive dialog | Filled red — only place a filled danger button is allowed |
| `.btn--mint` | Terminal completion (Complete Workflow) | Mint fill, ink text. **Scarce: one per screen, or none** |
| `.btn--sm` | Compact size modifier | Smaller padding, text-xs |
| `.btn--lg` | Large size modifier | Larger padding, text-base |
| `.btn--circle` | Icon-only circular button | Equal padding, border-radius-full |

**Hierarchy rule:** at most **one filled button per screen**. If a page header
already has a `.btn--primary`, an empty state on that page uses `.btn--secondary`.
`.btn--positive` was retired — a green "Start" on every row of a list is exactly
the noise this system removes.

**Active state:** All buttons scale to 0.96 on press (`transform: scale(0.96)`).
**Stimulus:** Buttons with confirm dialogs use `data-turbo-confirm`.

### Cards (`cards.css`)

| Class | Use when | Visual |
|-------|----------|--------|
| `.card` | Any contained content block | Raised bg, 1px hairline border, radius-lg, no shadow |
| `.card--bordered-top` | Emphasis card | 3px neutral top border |
| `.card--question` `.card--action` etc. | Publishes `--step-hue` for nested tokens | **No colored border** — surfaces stay neutral |
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
| `.form-select--sm` | Compact select inside a dense row (admin table, pagination) | Tighter padding, `width: auto`. Sized like `.btn--sm` is to `.btn` |
| `.form-input--sm` | Compact text input inside a dense row (a table cell) | Tighter padding, `text-sm`. The text-input counterpart of `.form-select--sm` |
| `.form-hint` | Help text below input | text-xs, muted color |
| `.file-dropzone` | File upload drop target (import upload, the step panel's media) | Centred column, dashed hairline, canvas-alt fill; `.is-dragover` turns it solid + primary-soft |
| `.file-dropzone__empty` / `__selected` | The two states inside it | Stacked, centred; toggle with `.is-hidden` |
| `.file-dropzone__icon` / `__hint` | Icon and sub-label | Muted ink |

**Focus:** Inputs get `var(--focus-ring)` (2px solid primary) on `:focus-visible`.
**Dropzone:** `.file-dropzone` was used by `workflows/imports/new` and
`workflows/_preview_pane` for a long time with **no rule anywhere** — the import
page's primary control rendered as a bare icon and a line of text, no box, no
padding, no centring, and it read as broken. A class that looks like a component
is not one until a rule exists; check `getComputedStyle`, not the markup.
**Stimulus:** Forms with autosave use `data-controller="inline-autosave"` and
`novalidate` (see Recipe 3 for why).

### Dialogs (`dialogs.css`)

| Class | Use when | Visual |
|-------|----------|--------|
| `.dialog` | Modal container — always on a native `<dialog>` | Centred by `showModal()`, canvas bg, hairline border, shadow-lg, radius-lg; `::backdrop` is `--color-backdrop` |
| `.dialog--sm` | Small modal (confirm) | max-width 24rem |
| `.dialog--lg` | Large modal (forms) | max-width 48rem |
| `.dialog__header` | Title bar | Flex, border-bottom |
| `.dialog__body` | Content area | Padding, overflow-y auto |
| `.dialog__footer` | Action buttons | Flex end, gap, border-top |

**Stimulus:** there is no generic dialog controller. A feature's own controller
opens its dialog with `showModal()` and closes it (the admin Users dialogs are
the worked examples below). `dialog_controller.js` was a generic one that nothing
mounted; it was deleted 2026-09-10. There was also a
`dialog-manager` controller for single-open enforcement; it was deleted
2026-09-09 along with the nav menu. It was documented here as living on `<body>`
and never did — its only mount was the `<nav>`, coordinating the nav menu against
the search dialog, so removing the menu left it with one dialog and nothing to
close. Prefer `showModal()`, which makes Escape and backdrop-click native, over
reintroducing a coordinator.

**A native dialog is `<dialog class="dialog">` opened with `showModal()`.**
`dialogs.css` resets the UA dialog's padding and colour, keeps a gutter at phone
width, and paints `::backdrop` with `--color-backdrop`; the
`.dialog__header/body/footer` anatomy is unchanged. Close with `dialog.close()`,
and treat a click whose `target` is the `<dialog>` itself as a backdrop click.

**Close it on `turbo:before-cache`.** Turbo snapshots the page as you leave, and
an open dialog comes back on Back/Forward as a non-modal `<dialog open>` — no
backdrop, the page behind it live — still showing whatever it held. The password
reset dialog came back with the temporary password in it. Test it with
`assert_no_selector "dialog[open]", visible: :all`: a restored dialog fades in
from opacity 0, which Selenium reports as not displayed, so a visible-only
assertion passes with the fix removed.

**An error raised while a modal dialog is open must render INSIDE the dialog.**
`showModal()` promotes the dialog and its `::backdrop` to the browser's top
layer, which sits above every ordinary stacking context — so `#flash`, fixed
position and all, renders *behind* it whatever its z-index, and the author sees
a dialog that did nothing. Give the dialog its own `.form-error` (kept empty,
and `.form-error:empty` drops only its margin, so it costs no space **while
staying in the accessibility tree** — `display: none` would take a `role="alert"`
region out of the tree until the moment its text arrived, which is the case
assistive technologies are unreliable about), clear it when
the dialog opens, and have the refusal stream to both targets: a Turbo Stream
aimed at a target that is not on the page is a no-op, so the controller need not
know who asked. `steps/_target_picker` and `password_reset_controller.js` are
the worked examples. Verify this kind of claim by hit-testing —
`document.elementFromPoint(x, y)` at the flash's own coordinates returned the
`<dialog>` — not from a screenshot, where the flash may simply be off screen.

**Escape inside a dialog needs `stopPropagation` where a document-level Escape
listener exists.** `builder_controller` closes the whole step panel on Escape,
so dismissing the target picker took the panel down with it. Stop the event at
the dialog (`keydown.esc->…#stopEscape`); `stopPropagation()` does not cancel
the browser's own default, so the dialog still closes itself natively. Only
`preventDefault()` would break that.

The admin Users screens are the worked examples: `admin/users/show` (a two-step
password reset) and the bulk dialogs in `admin/users/index`. The old pattern — a
`.dialog-overlay` div toggled with `.is-hidden`, driven by `modal_controller.js`
— was deleted in Stage 3 once nothing rendered it. Every dialog is a native
`<dialog>`.

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
| `.badge` | Generic label | Inline-flex, text-xs. **Pill shape is opt-in**, not the default |
| `.badge--question` `.badge--action` `.badge--message` `.badge--escalate` `.badge--resolve` `.badge--sub-flow` `.badge--form` | Step type | Color from `--hue-*` token |
| `.badge--draft` `.badge--published` | Workflow status | **Plain text**, no pill |
| `.badge--admin` `.badge--editor` `.badge--regular` | User role | **Plain text**, no pill |
| `.badge--info` | Informational | **Plain text**, no pill |
| `.badge--alert` | Error/urgent — exceptional | Pill, negative-soft fill |
| `.badge--warning` | Warning/caution — exceptional | Pill, warning-soft fill |
| `.badge--group` | Tag/token with a remove affordance | Pill, neutral fill + hairline |
| `.badge` "Global" | A workflow everyone signed in can see | **Plain text**, no pill |
| `.badge--warning` "No audience" | A published workflow in no group — only admins and its owner see it | Pill: an exceptional state |
| `.badge--warning` "In no group" | A group's manager who is in no group — sees only Global workflows and is asked to choose groups | Pill: an exceptional state |
| `.badge--warning` "Members can't see this" | A featured workflow a team's members can no longer see (unpublished, or filed out of reach) — shown on the team page with the reason, not counted toward the 8. A visible row past the first 8 gets plain text instead, since members can still run it | Pill: an exceptional state |
| `.group-tree__managed` "Admins add people" | A group only administrators add people to | **Plain text**, no pill: a setting, not a problem |
| `.admin-group__meta` "Joined themselves" | A membership its person made | **Plain text** after the role |

**Tiering rule:** a badge is a pill only when it marks a **step type** or an
**exceptional state**. Ordinary status and role read as plain text, so a list
does not become a wall of pastel and the eye finds real problems instantly.

A builder step row used to carry a `.badge--warning` reading "No connections".
It is gone: a row now shows a pressable `.builder__door-stub` per unwired
answer, which names the answer and fixes it in one click instead of announcing
a problem. Do not bring the pill back — see the Row door stubs entry below.

### Flash Messages (`flash.css`)

| Class | Use when | Visual |
|-------|----------|--------|
| `.flash` | Notification bar | Fixed **bottom-right**, slide-in, click or × to dismiss, 5s auto-dismiss |
| `.flash__body` | The visible box — **required** | Carries the fill, padding, radius and text colour. A `.flash` without one is unstyled text floating over the page |
| `.flash__close` | Dismiss affordance | Icon button, inherits the body's text colour |
| `.flash--notice` | Success/info message | `--color-positive` fill, `--color-on-positive` text |
| `.flash--alert` | Error message | `--color-negative` fill, `--color-on-negative` text |

**Never render a flash by hand.** `render "shared/flash_messages"` — every layout
uses it. There were three copies before, and the Player's had drifted into a bare
`<div class="flash flash--alert">` with no `.flash__body`, so flashes on the
surface agents live in rendered as unstyled ink text over the page.

**In-page changes report through `#flash`.** The application layout wraps the
flash render in `<div id="flash">`, so a Turbo Stream response can set
`flash.now` and `turbo_stream.update "flash", partial: "shared/flash_messages"`.
The group page's members and folders cards do this. `.flash` is fixed-position, so
the wrapper takes no space.

**A change the page makes itself reports the same way.** When there's no server
answer to carry a flash (a drag that didn't save), call `flashAlert(message)` from
`app/javascript/services/flash.js`. It copies the empty alert the layout keeps in
`<template id="flash-alert-template">`, so the markup lives once, in
`shared/_flash_message`. That template puts an empty `.flash` on every page with
the application layout, and Nokogiri's HTML5 parser matches inside `<template>`,
so scope flash assertions in tests to `#flash`. An unscoped `.flash` selector finds
the empty copy, and a "a flash rendered" check can then never fail.

**Why bottom-right.** The header is 4rem tall, so the old `top: 5rem` put the
toast on the page's top-right action zone — and a flash usually reports on the
very action whose button it covered (a failed publish hid Publish and Export).
Every corner was measured and every corner has controls in some page, so the goal
is not "no overlap" but "only overlap what survives the 5s dismissal". Bottom-right
covers repeated table rows, never a unique primary action. It stays click-to-dismiss
rather than `pointer-events: none`: click-through trades a blocked control for an
accidentally fired one.

### Navigation (`navigation.css`)

| Class | Use when | Visual |
|-------|----------|--------|
| `.page-header` | Top nav bar | Fixed top, white bg, border-bottom, z-nav |
| `.page-header__inner` | Max-width container | 80rem max, padding-inline |
| `.page-header__row` | Two-zone grid | `grid-template-columns: 1fr auto` |
| `.nav__links` | The destination row | Flex, stretched to full header height |
| `.nav__link` | One destination | text-sm/500 muted; current gets primary + 2px rule |
| `.nav__brand-link` | Wordmark, and the home link | Leads the row; `flex-shrink: 0` |

**Structure:** Left zone (brand, then destinations), right zone (search, theme,
avatar). Height: 4rem.

**The bar lists places, and every place is a labelled link.** No menu holds a
destination. It used to be a three-zone grid with the wordmark centred and a
1.4rem chevron beside it opening a dropdown of admin links — which meant `/admin`
was reachable from nowhere else in the header, and that a chevron next to a
wordmark (which means "switch workspace" in every app that has one) was doing a
plain link's job. Destinations also sat in the right zone against the theme
toggle and avatar, where a place reads as a setting.

**Teams** shows only to administrators and the managers of groups
(`User#can_curate_teams?`), the same way Analytics shows only to those who can use
it. A place a manager returns to belongs in the bar, not behind a link on another
page.

**Current state must be a different channel from hover, not a darker shade of
it.** `.nav__link[aria-current="page"]` takes `--color-primary-text`, weight 600
and a 2px `--color-primary` rule on the header's own hairline — the same
treatment as `.tab-bar__tab.is-active`, and for the same reason. The previous
version moved active from `--color-ink-subtle` to `--color-ink`, which is
precisely what `:hover` did, so the two were indistinguishable. Which page counts
as current is `NavHelper#nav_current`, section-level, never an inline ternary in
the layout.

**Narrow widths hide the wordmark's text and then scroll the destinations** —
they never collapse into a menu. Hiding destinations behind a trigger is the
failure this bar exists to undo, and doing it below 640px only would make the fix
evaporate exactly where re-finding things is hardest. `.nav__brand-link` carries
`flex-shrink: 0` because a squeezed row shrank it to *zero width*, taking the
icon with it and leaving the bar with no identity at all.

**Stimulus:** `data-controller="nav-search"` for Cmd+K search. That dialog is the
header's only one — it uses `showModal()`, so Escape and backdrop-click are
native and it needs no coordinator.

**Admin has a second level: a section sidebar.** Admin pages render through
`layouts/admin`, which fills `:content` with `.admin-shell` (sidebar + page) and
renders the application layout, so the top bar still lights Admin. The sidebar
lists Overview · Users · Groups │ Data Health · Email as labelled
links — ordered by use, the divider setting apart the pages you open when
something is wrong. Below 1024px it is a row that scrolls sideways, for the same
reason the top bar never collapses into a menu. Which item is current is
`AdminHelper::ADMIN_SECTIONS`; **add an admin controller to it when you add an
admin surface.** It replaced a dashboard of six buttons that left every other
admin page a dead end. Sub-pages inside a section (a group, its folders, its
forms) say where they sit with a parent-group breadcrumb (`admin/_breadcrumb`,
on `.wf-breadcrumb`), never a "Back to X" button.

**The sidebar takes ~13rem, so a wide admin table has ~980px, not ~1216px.**
When the Users table first gained the sidebar, a check for buttons wrapping onto
a second line passed while Deactivate ran 49px past the card edge in bulk mode.
Measure an admin table against its container's edge, not by looking for line
breaks.

### Tabs (`tabs.css`, `workflows.css`)

Two components, two different jobs. Do not conflate them.

| Class | Use when | Visual |
|-------|----------|--------|
| `.tab-bar` / `.tab-bar__tab` | **Navigating** between views of one record (Execution Path / Results Summary) | Bare text on a hairline rule; active tab gets navy text + 2px underline |
| `.wf-status-tabs` / `__tab` | **Filtering** a list (All / Published / Drafts) | Segmented pill control in a bordered track; active segment is a raised pill |

Active state is `.is-active` on both. `data-controller="tabs"` toggles it for you,
so `.tab-bar` drops into any existing tablist with no JS change.

### Other Components

| Component | Classes | File | Notes |
|-----------|---------|------|-------|
| Answer cards | `.radio-card`, `.radio-grid`, `.radio-list` | `runner.css` | The runner's answer choices. Deliberately **neutral** — no icons, no radio dot, no semantic colour. A question's polarity is arbitrary ("Is the site down?" makes Yes the bad news), so green/red miscommunicates while spending the scarce semantic budget. Label is the content, border is the state |
| Choice cards | `.choice-cards`, `.choice-card` | `forms.css` | `render "steps/fields/choice_cards", form:, attribute:, choices:, selected:, labelled_by:` — pick one of N as real radios in labelled cards. The chosen card is `.choice-card:has(> input:checked)`, so no controller keeps a class in step with a hidden field (that is what `selection-group` did wrong; deleted 2026-09-15). Each radio autosaves on change; a caller's own `input_data[:action]` runs first and may `stopImmediatePropagation()` to veto the save |
| Attachment list | `.media-list`, `__row`, `__row--pending`, `__thumb`, `__icon`, `__name`, `__size`, `__progress`, `__remove` | `_media.css` | `render "steps/media_list", step:, removable:` — the one list of a step's media, replaced whole by `Steps::MediaAttachmentsController` after an attach or a Remove. Files attach on choose via direct upload (`media-attachments` controller), with a `<progress>` row while they go. The runner keeps `steps/_media_attachments`, which shows images inline |
| Runner thread | `.runner-thread`, `__card`, `__check`, `__kind`, `__current`, `__complete` | `runner.css` | The run as one growing list: answered steps as compact cards (completion dot, type label, `title → answer`), then the open card. The dot is the one place step colour appears outside a badge. Answered steps were one-line rows first — see §Surfaces Deliberately Excluded for why that lost |
| Door rows | `.step-doors`, `__list`, `__row`, `__label`, `__target`, `__target--stub` | `steps.css` | `render "steps/doors", step:, workflow:, readonly:` — the ways out of the open step, one row each: the answer's label, then where it goes or a muted `__target--stub` saying it goes nowhere yet. Hairlines and muted text only: an unwired answer on a draft is work in progress, not a warning, so no semantic colour. It sits INSIDE the panel's autosave form, so it holds no `<form>` — New step is `<button type="button">` opening the type picker, Remove is a `link_to` with `data-turbo-method`. The readonly branch omits the buttons from the markup rather than hiding them in CSS |
| Outline door chips | `.builder__node`, `.builder__outline-branch`, `.builder__outline-door` (`--step`, `--jump`, `--stub`, `--extra`, `--continue`), `.builder__outline-chip`, `.builder__outline-jump`, `.builder__door-stub`, `.builder__door-stub-text`, `.builder__ways-in`, `.builder__outline-section` | `builder.css` | The step list is an outline (`workflows/_step_outline`, `_step_node`): each step is a `role="treeitem"` node holding its row, its exit doors in a `role="group"` down a hairline guide, then its continuation door, whose step is the next sibling. A door is a chip: a wired one is text beside the target's type dot; a stub is ONE `button.builder__outline-chip.builder__door-stub` (`No → add step`) that opens the type picker, dashed hairline and link colour, never a warning colour; a jump is ONE `button.builder__outline-jump` naming the step it leads to (`Yes → Working · step 4`), which opens that step. The jump is inline flow, not flex: a flex container blockifies its text runs and broke its reading into lines. `__door-stub-text` is the view-mode reading of a stub. A step two or more connections lead into shows `.builder__ways-in` ("2 ways in", the sources in its `title`). Steps nothing leads to follow an `Unconnected` section heading |
| Type picker | `.builder__type-picker`, `--floating`, `.builder__type-option` | `builder.css` | The seven step types as a `.dropdown__menu`. `--floating` is the modifier `step-list#positionPickerNear` adds when the picker was opened from a door rather than the bottom prompt: it switches positioning to `position: fixed` (escaping the list's `overflow-y` clipping) and gives the menu a fixed width, since it can no longer span the trigger the way the bottom-anchored picker spans the prompt row — the coordinates themselves are inline one-off layout values. Anchored to the bottom prompt, a stub on row 1 of a long list opened its picker ~650px away. Measure such a menu with `offsetWidth`/`offsetHeight`: it enters via `@starting-style` with a `scale()`, so a `getBoundingClientRect` read in the same tick as un-hiding it is the scaled size. It lives INSIDE `.builder__list`, which is why that list is hidden with `visibility: hidden` at ≤640px with a panel open, never `display: none` — a `display: none` ancestor would drop this picker from the render tree too, and the panel's own "New step" buttons (outside the list) still need to reach it |
| Mode-only elements | `.builder__edit-only`, `.builder__view-only` | `builder.css` | Shown or hidden by `data-builder-mode-value` on the builder container: `__edit-only` for a control (a stub button, a delete), `__view-only` for the plain-text reading of the same fact. Both are rendered; neither is a permission guard — the server renders the readonly panel without the forms at all |
| Step target list | `.step-target-list`, `__option`, `__title`, `__meta` | `steps.css` | The "Use existing…" dialog's body (`steps/_target_picker`): every other step in the workflow as a flat, filterable list, since at thirty steps typing beats scrolling. The dialog carries its own `.form-error` above the list — a refusal cannot be left to `#flash` (see § Dialogs) — which `.form-error:empty` collapses (margin only, never `display: none` — it carries `role="alert"`, and the element must stay in the accessibility tree before its text arrives; the controller streams `turbo_stream.update` into it, so the element itself persists and only its contents change, which is what makes it a live region at all) |
| List rows | `.list-section`, `.list-row`, `.list-row--compact` | `lists.css` | Section + hairline-divided rows. `--compact` is the dense size (builder step list); same anatomy, tighter box — sized like `.btn--sm` is to `.btn` |
| Player index row | `.player-row`, `__run`, `__pin` | `_player.css` | A `/play` row: the Run button (a `button_to` whose form is `__run`) and, for a Regular user, a pin toggle in `__pin` beside it. The wrapper carries the divider and `data-player-filter-target="card"`, so a search hides the toggle with its row. Hover lights only the Run area, telling it apart from the toggle |
| Pin toggle | `.pin-button`, `.is-pinned` | `dashboard.css` | `render "workflows/pins/toggle", workflow:, pinned:, location:`, where location is `pinned`, `recent` or `play`. A bookmark button with a 2.5rem square target: a solid bookmark in primary text when pinned, outline in muted ink when not. Its id is `dom_id(workflow, "pin_#{location}")`, so every copy on a page is replaced after a pin change |
| Skeletons | `.skeleton`, `.skeleton--text`, `--heading`, `--card` | `skeleton.css` | Shimmer animation, use for loading states |
| Pagination | `.pagination-bar`, `.pagination`, `.pagination__item`, `.is-active` | `pagination.css` | `.pagination-bar` is a three-zone grid: summary left, numbered nav centred, page-size right |
| Admin sidebar | `.admin-shell`, `__main`, `.admin-nav`, `__list`, `__link`, `__label`, `__divider`, `__count` | `admin.css` | Second-level nav for admin pages (see § Navigation). Current is `[aria-current="page"]`: primary-soft fill + primary text + weight — a different channel from hover. `__count` is a `.badge--warning`, rendered only when something needs attention, and counts *kinds* of problem, not affected records |
| Needs attention | `.list-section.admin-attention` + `.list-row`, `.admin-attention__people`, `__meta`, `__clear` | `lists.css`, `admin.css` | The admin Overview. One row per kind of problem, each naming the problem, its cost in one line, and a secondary link to where it is fixed — no filled button. Rows align to the top, since one can list ten people. Nothing waiting renders one line (`__clear`), not an empty section |
| Resume card | `.home-resume`, `__eyebrow`, `__title`, `__meta`, `__blockers`, `__actions` | `dashboard.css` | The Editor and Admin home's hero: the workflow you were last in, with the page's one filled button (Continue editing). A draft's publish blockers are a `.badge--alert` linking to the health panel. Below it, "Waiting on you" reuses `.list-section.admin-attention` rows that name the workflows each covers, so one kind of problem is one row |
| Group picker | `.group-picker`, `__global`, `__hint`, `__search`, `__filter`, `__list`, `__option`, `__label`, `__name`, `__path`, `__note`, `__empty` | `forms.css` | `render "shared/group_picker", nodes: Group.tree_nodes, field_name:, selected_ids:, input_data: {}`. Every group as a checkbox, indented by depth, with its full path; `group-picker` filters by any part of the path. Flat rather than an expandable tree — at hundreds of department groups typing beats expanding. Costs one query however many groups exist; never build paths with `Group#full_path` in a loop. Global (when in `nodes`) renders on its own row above the list and outside the filter. Membership pickers pass `Group.assignable_tree_nodes`, which omits it; the builder's Details panel passes `tree_nodes(within:)` and its autosave action as `input_data`. Pass `notes: { id => text }` for a line under a group: its description on `/welcome` and My groups (both scoped to `Group.self_joinable_ids`, My groups minus what's already joined), "Joined themselves" on the admin user page. A note is read as the checkbox's description (`aria-describedby`, hidden from the label's own text), not as part of the group's name |
| Group tree | `.group-tree`, `__toolbar`, `__filter`, `__list`, `__row`, `__toggle`, `__spacer`, `__label`, `__name`, `__path`, `__count`, `__empty` | `admin.css` | The admin groups index. Flat depth-first rows with `--tree-depth` set inline and `data-ancestors`; `group-tree` hides a row unless every ancestor is expanded, and while filtering shows matches (with `__path`) plus the groups above them. Toggle state is `aria-expanded`, which also rotates the chevron. Counts are plain text, never pills |
| Admin cards | `.admin-card__heading`, `__heading--danger`, `__action-row`, `.admin-card--danger` | `admin.css` | Shared by the user page and the group page: a card heading, a sentence beside its one action (wraps once the sentence would squeeze below 16rem), and the danger card's red hairline |
| Group page | `.admin-group__header`, `__title`, `__list`, `__item`, `__name`, `__meta`, `__search`, `.admin-folders__handle`, `__rename` | `admin.css` | `admin/groups/show`: hairline-divided rows inside a card — subgroups, members, folders — each name, a muted meta line and at most one plain or secondary action. No filled button on the page; Delete Group is outlined `.btn--negative`. At `Group::MAX_DEPTH` Add Subgroup gives way to one `.form-hint` line saying the group is at the limit. The member search field sits outside `turbo-frame#group-member-search` and fills it as you type |
| Team page | `.admin-group__list`, `__item`, `__name`, `__meta`, `__search`, `.admin-folders__handle`, `.badge--warning` | `admin.css`, `badges.css` | `teams/show` and `teams/index`, outside the admin area. They reuse the group page's hairline row anatomy rather than a second list style. One card, `#team-featured`: rows with a drag handle (`sortable-list`), Move up, Move down and Remove as `.btn--plain`, and a "Members can't see this" warning pill, with its reason, on a row members can no longer see. A visible row past the first 8 says "Past the first 8 · not on members' home pages" as plain text in its meta line: members can still run it from `/play`, so nothing is wrong. The add search follows the member search's rule: the field sits outside `turbo-frame#team-featured-search`. No filled button on either page |
| From your team | `#team-workflows-section`, `.dashboard-team__heading`, `dashboard/_launcher_row` | `dashboard.css`, `lists.css` | The CSR home's section above pins: a small heading per team ("For everyone" for Global, and the team's path when two of the CSR's teams share a name), rows from the launcher-row partial with Run only. When nothing is featured only the empty wrapper renders (no card), so a pin change always has a target to replace |
| Data Health | `.admin-health`, `__hint`, `__hint-row`, `__after`, `__list`, `__grid--2`, `__grid--3`, `__server`, `__settings`, `__schedule`, `__steps` | `admin.css` | `admin/data_health`: each section is a `.list-section` head, one hint saying what the numbers mean, then a `.stat-panel`. Background Jobs leads with a Worker cell (Running or Not running, from the Solid Queue heartbeat); `__steps` is the server notes' numbered restart steps. The grid modifiers exist because `.stat-panel__grid`'s hairlines assume four cells. No filled button; a failed job's Discard is `.btn--plain` with a confirm, not a red outline repeated down the list |
| Admin disclosure | `.admin-disclosure`, `__summary`, `__pre` | `admin.css` | A `<details>` for what most admins never open: a failed job's full error, Data Health's server notes. `.step-disclosure` is the builder's and lives in `steps.css` |
| Email card | `.admin-email__section`, `__source`, `__switch`, `__subheading`, `__footer` | `admin.css` | `admin/smtp_settings`: one form card. The source line and its "Use these settings" switch come first, then Server / Credentials / Delivery under small uppercase subheadings with hairlines between; Save in `.card__footer` |
| Analytics card subtitle | `.analytics-card__subtitle` | `admin.css` | A card header's second line. `.empty-state__text` is copy for an empty panel, not a subtitle |
| Outcome bars | `.analytics-bar--resolved`, `--completed`, `--escalated`, `--error`, `--transferred`, `--muted`, `--default` | `admin.css` | Chosen by `AnalyticsHelper#analytics_outcome_bar_class`, never in the view. Transferred takes the sub-flow hue (a handoff is a sub-flow that doesn't return); abandoned and in-progress runs are muted grey. The bar carries the hue; the outcome label is plain text |
| Icons | `.icon`, `.icon--xs/sm/lg/xl` | `icons.css` | Inline-flex sizing (0.75 to 2rem) |
| Dark mode toggle | `.dark-mode-toggle` | `buttons.css` | Circular icon button in a header. Lives in components, not `navigation.css`, because the Player's layout renders it without loading the nav module — a class styled only in a sheet that layout does not load matches nothing at all. (It used to *also* fall back to raw browser chrome; `reset.css` now neutralises button background, border and padding, so that half is closed — see § The unstyled-button trap) |

### Empty States

**Keep the frame, and say what will fill it.** The container, card border, and
(for charts) the axes and gridlines still render — only the data is missing. The
description is an instructive sentence about what will appear here, not an
apology. If the page header already has a filled button, the empty-state CTA is
`.btn--secondary`.

```html
<div class="card" style="padding: var(--space-8); text-align: center;">
  <svg class="icon icon--xl mx-auto mb-4">...</svg>
  <h3 class="font-semibold mb-2">No items found</h3>
  <p class="text-sm" style="color: var(--color-ink-muted);">Description text here.</p>
  <div class="mt-4">
    <a href="..." class="btn btn--secondary btn--sm">Create New</a>
  </div>
</div>
```

### Error/Validation States

- **Inline field errors:** Add `.is-invalid` to the control and display error text in a `<span class="form-error" role="alert">` below it. Defined for `.form-input`, `.form-textarea` and `.form-select` (red border) and for `.form-checkbox`/`.form-radio` (red outline — a native checkbox draws its own box, so a border-color is invisible on it). The runner's form step is the worked example: `scenarios/_form_step`.
- **Flash errors:** Use `.flash--alert` for page-level errors.

### Utility Classes vs. Component Classes

Use **component classes** for what things ARE: `.btn--primary`, `.card`, `.form-input`.
Use **utility classes** (from `utilities.css`) for layout glue: `.flex`, `.items-center`, `.gap-3`, `.mb-4`, `.text-sm`, `.font-semibold`.

Rule: if you're describing a component's identity, use a component class. If you're adjusting spacing or layout between components, use a utility class.

### Common Stimulus Controllers

These are the most-used controllers. Wire them via `data-controller` on the appropriate element.

| Controller | Purpose | Common data-actions |
|-----------|---------|-------------------|
| `inline-autosave` | Debounced form autosave (2s) | Listens for `input`, `change`, `lexxy:change` |
| `media-attachments` | Direct-upload a chosen or dropped file, show progress, attach it to the step | On the panel's media block, with `url`, `direct-upload-url`, `max-bytes`, `allowed-types` values; `change->media-attachments#fileSelected` on the file input |
| `dropdown` | Toggle dropdown menus | `click->dropdown#toggle` |
| `clipboard` | Copy text to clipboard | `click->clipboard#copy` |
| `nav-search` | Cmd+K fuzzy search | On search input |
| `step-warnings` | Async health check, inline warning icons, popover | On builder container, auto-fetches after saves |
| `step-list` | The type picker. A control that grows a step from a door carries `data-grow-from`, `-label`, `-condition` and `-context`; the picker copies them into its hidden fields when it OPENS (choosing a type closes it before the form submits, so writing on close sends a grow with no parent) | `click->step-list#growFromDoor` on an outline stub chip; a panel button outside the list element is picked up by a document listener |
| `step-target-picker` | The "Use existing…" `<dialog>` on a door row: which door it is for, the filter, and a refusal rendered inside the dialog | On the panel body; `click->step-target-picker#open` on the door's button, `keydown.esc->step-target-picker#stopEscape` and `click->step-target-picker#backdropClose` on the dialog |
| `scenario-step` | Player step interactions | On step card, handles auto-advance |
| `tabs` | Tab switching | `click->tabs#select` |
| `inline-rename` | Rename in place: Enter or blur saves once, Escape reverts | On the one-field form; `input` target with `keydown.enter->inline-rename#commit blur->inline-rename#commit keydown.esc->inline-rename#revert` |
| `debounced-submit` | Submit a form once typing pauses (300ms) | On the form, with `input->debounced-submit#submit` on the field. Keep the field outside any frame the form targets, or each answer replaces the input being typed in |
| `sortable-list` | Drag to reorder a list whose items carry `data-sortable-id`; on drop, PATCHes the ids in order and renders a Turbo Stream answer. A failed save (an error such as the 401 a lost session answers with, no answer, or a redirect such as lost access, which it doesn't follow) puts the rows back and reports through `#flash` | On the list, with `data-sortable-list-url-value` and `data-sortable-list-param-value` (e.g. `folder_ids`, `featured_ids`); drag handle `.cursor-move` |

---

## Section 3: Page Recipes

Each recipe shows the complete HTML structure for a page type. Use these as starting points for new views.

### Recipe 1: Dashboard / Index Page

Section heading sits **on the canvas**; the bordered container holds only rows.

```erb
<div class="page-content">
  <!-- Page header: title left, ONE filled action right -->
  <div class="page-header-section">
    <h1 class="page-header-section__title">Page Title</h1>
    <div class="flex items-center gap-2">
      <a href="..." class="btn btn--secondary btn--sm">Import</a>
      <a href="..." class="btn btn--primary btn--sm">New Item</a>
    </div>
  </div>

  <!-- Section: bold title + count badge + text link, ABOVE the container -->
  <section class="list-section">
    <div class="list-section__head">
      <h2 class="list-section__title">Recent Items</h2>
      <span class="list-section__count"><%= items.size %></span>
      <%= link_to "View all", items_path, class: "list-section__link" %>
    </div>

    <div class="list-section__body">
      <% items.each do |item| %>
        <div class="list-row">
          <span class="list-row__icon" aria-hidden="true">
            <%= icon "document-text", class: "icon icon--sm" %>
          </span>
          <div class="list-row__body">
            <div class="list-row__title">
              <%= link_to item.title, item_path(item) %>
              <span class="badge badge--published">Published</span>
            </div>
            <p class="list-row__sub">Created <%= time_ago_in_words(item.created_at) %> ago</p>
          </div>
          <div class="list-row__actions">
            <%= link_to "View", item_path(item), class: "btn btn--secondary btn--sm" %>
          </div>
        </div>
      <% end %>
    </div>
  </section>
</div>
```

**Anatomy of a row:** icon chip (neutral) → semibold title → grey subtitle →
optional inline progress → outlined action pinned right. Rows are divided by
`border-bottom` hairlines, never by gaps or shadows. The icon chip stays neutral;
it is not a place to signal step type.

**Stats** use `.stat-panel` — ONE bordered card whose `.stat-cell` children are
divided by hairlines — not a grid of separate cards.

### Recipe 2: Detail / Show Page

Single-column content with a header and sections.

```erb
<div class="page-content">
  <div class="page-main">
    <!-- Header: back link, heavy H1, small grey identifier -->
    <div class="page-header-section">
      <div>
        <%= link_to parent_path, class: "page-back" do %>
          <%= icon "chevron-left", class: "icon icon--xs" %>
          Back to <%= @item.parent.name %>
        <% end %>
        <h1 class="page-header-section__title"><%= @item.title %></h1>
        <p class="page-header-section__ident"><%= @item.identifier %></p>
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

**Tabbed detail pages** put a `.tab-bar` directly under the header (see "Tabs").

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
        <%= form_with model: @item, class: "space-y-4", html: { novalidate: true },
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

**An autosave form carries `novalidate`.** `inline-autosave` submits with
`requestSubmit()`, which runs the browser's required-field check, and a refused
autosave is silent: the edit is dropped. The builder's step panel lost every
edit to a new Question this way until 2026-09-10, because its Question text
was `required` and starts empty. Say what must be filled in through the health
check, not with `required`. Pass it as `html: { novalidate: true }`: `form_with`
drops a bare `novalidate:` without a word, which is how the first version of
that fix rendered nothing.

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
          <button class="btn btn--negative btn--sm">Delete</button>
        </div>
      </div>
    </div>
  </div>
</div>
```

**Pattern:** Each settings section is a `.card` with a heading, description, and setting rows. Danger zone card uses `border-color: var(--color-negative)` for visual warning.

### Recipe 5: Player Page (Lightweight Skeleton)

**Run** screens use a **separate layout** (`layouts/player.html.erb`) and **separate CSS** (`_player.css`). Do not use the main application layout for those.

`/play` is **not** one of them. It is a browse page — heading, filter, list rows —
and it renders the application layout with the normal top bar, so ⌘K works there
and Play shows as current. The chrome falling away is what tells an agent a run
has begun; it should not also fall away for choosing one. Add a Player action to
the run set only if it *is* a run.

```erb
<%% content_for(:title) { "Workflow Title — TurboFlows Player" } %>

<!-- The whole page below the chrome. No progress bar and no step numbers:
     see §Surfaces Deliberately Excluded for why both were removed. -->
<%= render "runner/thread",
      scenario: @scenario,
      step: @parked ? nil : @current_step,
      next_url: player_scenario_next_path(@scenario),
      stop_url: player_scenario_stop_path(@scenario),
      back_button: player_back_button(@scenario),
      show_cancel: current_user.present?,
      errors: @step_errors || [],
      submitted: @submitted || {},
      auto_advance: @current_step && !@parked ? runner_auto_advances?(@current_step) : false,
      parked: @parked,
      results_url: player_scenario_show_path(@scenario) %>
```

**The shell has no branches.** Everything route-shaped is a local, and the
thread decides what to render — the open card, a Resume control, or the run's
ending. Do not add an `if` about how the run renders to a shell; that split is
what the shared partials exist to prevent.

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
| `app/views/player/step.html.erb` | Step execution | A thin shell: page chrome and route-shaped locals only, with everything below delegated to `runner/_thread`. Fifteen lines and no branches — the whole file. No progress stepper: see the Scenario runner entry in §Surfaces Deliberately Excluded for why the numbers and bars went |
| `app/views/workflows/_builder.html.erb` | Builder/editor | Header with inline edit, panel system, toolbar, Stimulus wiring. Its chrome now follows this guide; the editing internals it opens into are still excluded (see §Surfaces Deliberately Excluded) |
| `app/views/runner/_step_body.html.erb` | Shared body across two shells | Keeping two surfaces from drifting: route-shaped values (`next_url`, `stop_url`, `back_button`, `show_cancel`) arrive as locals, so the partial never calls a route helper and the Scenario/Player difference lives only in the two shells |
| `app/views/workflows/_step_row.html.erb` | Dense list row | Composing `.list-row` + `.list-row--compact` with block-specific concerns, rather than redefining a row. Status/meta sits inline, not on a second line — a scanned list pays for two-line rows in steps visible at once |

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
| `forms.css` | components | Form controls, file dropzone, group picker |
| `dialogs.css` | components | Modal dialogs |
| `dropdowns.css` | components | Dropdown menus |
| `tables.css` | components | Data tables |
| `badges.css` | components | Badges, pills, dots |
| `flash.css` | components | Flash messages |
| `icons.css` | components | Icon sizing |
| `skeleton.css` | components | Loading skeletons |
| `pagination.css` | components | Page navigation (« ‹ 1 2 3 › » + summary) |
| `tabs.css` | components | Underline tab bar (`.tab-bar`) |
| `lists.css` | components | Section + row list pattern: `.list-section`, `.list-row`, `.list-row--compact` |
| `_tags.css` | components | Tag pills, autocomplete |
| `_player.css` | components | Player-specific styles |
| `_form_step.css` | components | FormStep builder UI |
| `_media.css` | components | The step panel's attachment list and the runner's inline media display |
| `_version_diff.css` | components | Version comparison |
| `flow_diagram.css` | components | Flow diagram layout |
| `session_timeout.css` | components | Session timeout UI |
| `navigation.css` | modules | Top nav bar |
| `layout.css` | modules | Page structure (.page-body, .page-main) |
| `builder.css` | components | Builder-specific styles (includes health panel, inline warnings, the type picker and its floating variant, the step outline and its door chips) |
| `workflows.css` | modules | Workflow list/show styles |
| `runner.css` | modules | The Scenario + Player runner: answer cards, the runner thread, step content box |
| `scenarios.css` | modules | Scenario **results** page only — the runner half lives in `runner.css` |
| `steps.css` | modules | Step editor styles: the panel's fields, the step disclosure, door rows, the target-picker list |
| `editor.css` | modules | Grab bag, and mis-described here for a long time: it is not the Lexxy editor. It holds the button spinner, collaboration presence styles, empty-state text, the inline step creator, the step outline wrapper, the step editor's two-column layout and a flow preview section. The visual-editor chrome it also carried was deleted 2026-08-29, and the CSS of the unmounted Stimulus controllers (template cards, condition tokens, branch and step pickers, variable autocomplete) on 2026-09-10 |
| `dashboard.css` | modules | Dashboard shell: `.dashboard-*`, `.home-resume`, `.stat-panel`/`.stat-cell` |
| `auth.css` | modules | Login/signup pages |
| `admin.css` | modules | Admin shell (section sidebar), needs-attention list, breadcrumb spacing, users filter/bulk bar, group tree, user and group pages, Data Health, the admin disclosure, the Email card, analytics bars and card subtitles. Tokens only — `test/stylesheets/admin_css_audit_test.rb` refuses literal colours and theme blocks |
| `utilities.css` | utilities | Layout utilities (.flex, .gap-*, .mb-*, .text-*) |
| `animations.css` | utilities | Keyframes (fadeIn, slideIn, scaleIn, shimmer) |
| `print.css` | utilities | Print styles |

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
9. **At most one filled button** on the screen
10. **Badges**: pill only for step types and exceptional states
11. **Step color** goes through `--step-*` tokens, never inline `oklch()`
12. **Text on a semantic fill** uses `--color-on-*`, never hardcoded white
13. **Verify in the browser, in both themes.** Passing tests prove nothing about
    color. Read `getComputedStyle` on the element — a token that silently fails to
    resolve renders as "no style applied", which looks plausible in a screenshot
14. **Tabs match their job** — `.tab-bar` (underline) for *navigating* between
    views of one record; `.wf-status-tabs` (segmented) for *filtering* a list.
    Wearing the filter control for navigation was the most-repeated mistake of
    the migration
