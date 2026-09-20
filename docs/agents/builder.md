# The builder: step panel, doors, growing, connections

> Part of the agent guidance for TurboFlows, and as binding as `AGENTS.md`, which indexes it.
> Moved here verbatim from `AGENTS.md` on 2026-09-20 so it loads only when the work needs it.
> Cross-references written as "Builder UI §…" mean `docs/agents/builder.md`; "Workflow Engine" and
> "key-services entry" mean `docs/agents/workflow-engine-and-import.md`.

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
- `panel_title_controller.js` — keeps the step panel's header in step with the title field as it is typed. Declared on the builder's own `<turbo-frame id="builder-panel">` **and** on the one `steps/_panel_edit` renders, because the two delivery paths differ: a frame navigation replaces the frame's CONTENTS and keeps the element (so attributes on the incoming tag are discarded), while `turbo_stream.replace "builder-panel"` (a grow) replaces the element itself
- `builder_controller.js` — panel open/close, step selection, title autosave, Escape to close, `openHealth` action, auto-opens health panel when `?health=true` URL param is present
- `step_list_controller.js` — SortableJS reorder + the type picker: opening it for a door (from a row's stub or the panel's "New step"), writing the `data-grow-*` fields, and floating it beside its trigger
- `step_target_picker_controller.js` — the "Use existing…" dialog on a door row: which door it is for, waiting for the panel's pending save before the pick is sent, the filter, Escape (`stopPropagation`, or the whole panel closes behind it), and closing on `turbo:before-cache`
- `inline_autosave_controller.js` — debounced autosave (2s), `flush()` for whoever must act after the pending save (it returns a promise that resolves once nothing is in flight), the panel's **save indicator** (see below), listens for `lexxy:change` events, flushes pending saves on disconnect via `FormData` + `fetch`, dispatches `health:check-needed` after disconnect saves
- `step_warnings_controller.js` — async health check fetch, renders inline warning icons on step rows, toolbar issue count, click-to-open popover with Fix buttons. Listens for `turbo:submit-end`, `health:check-needed`, `turbo:before-stream-render`
- `template_picker_controller.js` — template popover in toolbar, applies workflow archetypes

**The panel header follows the title field as it is typed**, not the save. It
used to name the step as it was when the panel OPENED, so renaming one left it
reading "Untitled Question" above a field that said otherwise (the step's ROW
updated on save; only the header two inches from the field was stale). Showing
unsaved text there is honest only because the save indicator sits beside it and
says so — the two were ruled on together.

**The panel says what its autosave is doing.** A `[data-autosave-status]` span in
the step panel's header, driven by `inline-autosave` in four states: **Unsaved
changes** (dirty, the moment a field changes), **Saving…**, **Saved**, **Not
saved** (the server refused; the reason is in `#flash`, which is where it always
went). The dirty state is not decoration — the debounce runs for two seconds,
and an indicator reading "Saved" through them is a lie. It is NOT the builder
header's `#autosave-status`, which belongs to the workflow title; step saves
reported nowhere at all, which is how a refused save looked fine for months.
The controller holds the element from `connect` rather than looking it up when
needed (by flush time its form is detached), and skips it once it is off the
page: a flush sent as the panel closes answers after the NEXT panel has
rendered its own, and that one is not describing this save.

**Autosave pattern:** Every field change triggers `inline-autosave#schedule` (via `data-action` on inputs or `lexxy:change` listener on the form). On disconnect (e.g., switching steps), pending saves are flushed by snapshotting `FormData` and sending via `fetch()` POST with `_method=patch`. The step panel form carries `novalidate`: `requestSubmit()` runs the browser's required-field check, and while any `required` field was empty (a new Question's text, a Form row just added) every save was refused and the edit dropped. The health check says what still needs filling in.

**The panel still submits the whole step, but the server writes only what was
touched.** `inline-autosave` sends `step[dirty_fields][]` — the fields that
fired an `input`, `change` or `lexxy:change` — and `step[rendered][<field>]`,
the value the server put in that input when the panel rendered.
`StepsController#permitted_step_params` slices the permitted attributes by that
list, and a touched field whose `rendered` value no longer matches what is
stored means someone else wrote it while this panel sat open: the whole save is
refused **before `@step.update` runs**, so nothing is written, connections
included. A check placed after the update would be reporting a conflict it had
itself caused.

An **absent** `dirty_fields` key writes everything, exactly as before — that is
what keeps `step_field_map_test` (the publish/restore guarantee), imports and
any older client working. The panel therefore always sends the key, empty
sentinel included: with nothing marked dirty and no key at all, the fallback
would write everything and the mechanism would silently revert to clobbering
with every test still green. Two mutation checks passed for exactly that reason
before the sentinel existed.

**Three refusals now, and they must keep different words.** The connections
refusal happens *after* the step's fields are written and says so.
`SAVE_CONFLICT_MESSAGE` belongs to the `StaleObjectError` path — two writes
overlapping in the DATABASE — and says to reload, which is right when the
request never held the current row. `FIELD_CONFLICT_MESSAGE` must NOT say
reload: the author's typing is still on screen and their next keystroke retries.

**What is not conflict-checked, deliberately:** a field with more than one form
element. `options` is many inputs and a checkbox is two (Rails renders a hidden
`0` beside it), so neither carries a single rendered value and both keep
last-write-wins rather than getting a comparison that cannot be right.
`transitions_json` is outside the mechanism entirely — it has its own
`rendered`/`minted` protocol, and a second staleness mechanism on the same
payload is how the `known` conflation started.

**Comparison is per attribute type, and two normalisations are load-bearing.**
`type.deserialize` on the rendered side, not `cast`: `Type::Json#cast` returns a
String unchanged, so casting both sides compared a JSON string against an Array
and refused every `options` save for ever. And `""` folds to `nil`, because an
empty text input reads `""` where its column holds `nil` — without it every
optional field the author never filled in reported a conflict on its first save
and could never be saved again. Only `""` and `nil` fold; `false` stays distinct
from `nil`, which a `.blank?` test would not.

**Rich text takes its baseline from the SERVER, not the editor.**
`steps/_panel_edit` renders a hidden `step[rendered][<field>]` per rich-text
field from the stored HTML. `<lexxy-editor>` is form-associated and holds its
own normalisation of the body — an empty one reads `<p><br></p>` where the
column holds `""` — so snapshotting the editor would conflict with itself on the
first edit of every rich-text field. Those baselines ride along `disabled`
unless their field is dirty, since each is a full copy of the body (5.7KB
measured for an ordinary one, up to `MAX_STEP_CONTENT_LENGTH`) and the server
reads one only for a dirty field.

What marks rich text dirty is **not** the `lexxy:change` handler: an `input`
event raised inside the editor is retargeted to the form-associated host as it
crosses the shadow boundary, so it arrives already carrying the field's `name`.
Mutation testing established that; the `closest("lexxy-editor")` walk beside it
is an unproven guard for an event that is not retargeted, not covered behaviour.

A save that lands becomes the new rendered baseline (`adoptSentValues`). Without
it the author's next edit is compared against the value their own last save
replaced, and every second edit is refused as a conflict with themselves.

The dirty state is written into the form **before** `disconnect` snapshots its
`FormData`. `save()` writes it too, but on that path the snapshot has already
been taken, and that flush is the save most likely to be racing someone — it
fires when the author switches steps mid-debounce.

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
never fire (first match wins). **A grow goes after the panel's pending
save, never ahead of it.** The panel's doors are server-rendered, so inside the
autosave debounce they show the step as it WAS; a grow landing first wrote the
old door's connection and the flush behind it then changed the step under it —
a Text question's blank "Next" edge on what was about to be a Yes/No question,
catching both answers with the health check silent. `services/pending_panel_saves`
(`deferSubmitUntilPanelSaved`) awaits `inline-autosave#flush`, which saves
anything dirty and resolves once nothing is in flight, then resubmits. **Both**
buttons that act on a door use it, through a `submit` action on their form:
the type picker's (`step-list#growAfterPendingSave`) and the "Use existing…"
dialog's (`step-target-picker#pickAfterPendingSave`) — a pick names a door
exactly as a stub does and was as stale. And because the press may name a door the step no longer has,
`GrowStep.create` **refuses a door `Step::Doors` does not list** — no button
offers one, so only a stale press is refused. `GrowStep.create` meets the wired-door collision
the other way: it **refuses** (`GrowStep::Refused`) a door that is already
wired rather than retargeting it, because a grow only ever starts from a stub —
so a wired door there means the stub was stale (another editor wired it, or a
second click raced the first), and retargeting would silently strand the step
the door already led to. `StepsController#respond_to_refused_grow` answers with
the whole list and the parent's Connections fragment, so the stale stub goes. The one `update_column` here is
`assign_start_step`, moved from `StepsController` unchanged: a full save would
bump the workflow's `lock_version` under whatever the title or Details autosave
is holding and be refused as stale. Both `GrowStep` entry points hold a **row lock on the workflow**
(`Workflow.lock.find`, no `lock_version` bump) for their transaction, because
everything they do reads before it writes: on PostgreSQL four grows at once gave
positions `[1, 2, 2, 2, 3]`, and one door pressed four times grew three steps.
SQLite ignores `FOR UPDATE`, so only `test/services/grow_step_concurrency_test.rb`
can show it, on PostgreSQL — it skips itself locally and its header says how to
run it. Every grow replaces the **whole** step list
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
runner, against a runner that itself grew less strict. **Position counts too**, since 2026-09-19:
`StepResolver` takes the first match in position order and a blank condition
always matches, so only a transition sorted AHEAD of the first default edge can
claim a door. `Transition.settle_positions` keeps a default last for every
builder write, but an import can write one first — and a door that read as
wired below it was the same lie in a different place. That answer is a stub
reading `follows “Anything else”`, its dead edge is an extra, and `#shadowed`
lists every conditional edge in that state so `WorkflowHealthCheck` can say so
(`:shadowed_connection`, a warning whose Fix is `settle_connections` — it
re-sorts and changes no connection). `GrowStep` settles the order BEFORE it
reads the doors, and outside its own transaction: adding a second edge for a
shadowed door would be the wrong repair (the next settle hands the door back
to the old edge, stranding the new step), and a refusal must not roll the
repair back. What no door claims is
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
request has already been replaced by another. Its `.then` used to call
`Turbo.renderStreamMessage` only for a NON-OK response (a refusal), so a 200 —
which is what a heal answers with, flash included — was dropped with nothing
shown. **Fixed 2026-09-19:** it renders every stream answer. A stream aimed at
an element the page no longer has (the panel it came from has already been
replaced) is a no-op, so the rest costs nothing. That heal shares the same one-stream-per-target gate the rename and
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
win outright whenever either key is present as an Array, even an empty one
(the other may be absent, but a scalar there is refused as `Malformed` rather
than wrapped into a list),
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
current reader (`TransitionSync#shape_of`,
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
editor's snapshot is rebuilt rather than left naming the old identifier — and
that holds when the connections are then **refused**, which is the case that
used to skip it: `@step.update` has already committed the rename by the time
`TransitionSync` refuses, so `respond_to_connections_refusal` re-streams the
fragment too (only after a rename; any other refusal leaves the editor alone,
since the refused row is the author's to fix), along with the step's row, which
it also broadcasts, because the step's own fields did save. Which
fragment a save streams is decided in one place (`connections_or_doors_stream`):
a rename gets the whole `dom_id(step, :connections)`; so does a save that moved
a transition between doors and extras **in either direction** (a row the editor
was showing became a door, or a door stopped being claimed and became an extra
the editor has never heard of); otherwise a save that touched `answer_type`,
`options` or `transitions_json` gets the doors list alone. One stream per
target, never both. That decision reads the payload's shape through its own
method, `StepsController#shown_and_sent_row_uuids` — a SECOND, independent
reader of `rendered`/`minted`/`known`, kept apart from `TransitionSync#shape_of`
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

**A change to one step's connections reaches every open panel.**
`Steps::TransitionsController#broadcast_connections` and
`StepsController#broadcast_parent_connections` broadcast the
`dom_id(step, :connections)` fragment (and, for the transitions path, the
picker's own `steps/_target_picker_options`, which exists so the candidate list
can be replaced without closing an open `<dialog>`). Before this, both answered
only the editor who acted, and everyone else kept a stale doors list until they
saved or reopened the panel; the step-list broadcast never covered it, because
that replaces rows rather than an open panel.

Nothing identifies a sender — the acting editor receives their own broadcast
too — so **the browser decides whether to apply it**, in
`step_transitions#declineWhileDirty`. It tests the row's own CONTENT, not the
stream's origin and not an editor-dirty flag: it declines only while the editor
holds a row with **no target chosen yet**, which is exactly what
`TransitionSync#sync_row` writes nowhere and therefore the one thing no
incoming render can contain. Everything else is saved inside the 2s debounce,
which makes the incoming fragment server truth and worth taking. A declined
render leaves a persistent line in the editor rather than a flash: a flash
self-dismisses in five seconds and being out of date is durable until the panel
is reopened. It deliberately does not stash the fragment to apply later, since
applying HTML rendered minutes ago is the staleness this exists to cure.

**A dirty flag is the wrong instrument here, twice over, and both ways were
tried.** It cannot tell another editor's broadcast from the answer to this
panel's OWN save, because both land on the same target — so it cancelled the
author's own doors re-render, caught by the pre-existing grow test "a
connection made with the editor's No preset is read as the No door". And it
drifts: clearing it on a successful save was wrong too, because a row with no
target is written nowhere, so the save succeeded while the editor still held
that row and a broadcast two seconds later wiped it.

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
gone, which covers both this author's delete and a collaborator's. A missing
row is not always a delete, though: a list broadcast is rendered from a read
taken when it is sent, so one rendered before this author's grow committed can
arrive after the grow's response, and for that moment the new step has no row.
Nothing in the browser can tell the two apart, and guessing "stale" would leave
a panel open on a dead step — so the panel still closes at once, and
`syncSelectedRow` remembers which step it closed on (`closedOnMissingRowOf`):
if a later render brings that row back while no other panel has been opened, it
reopens from the row's own URL. A deleted step's row never returns, so a delete
is unchanged. (The TODO this closed proposed "close only after two consecutive
renders without the row" — that regresses the 404: a collaborator's delete is
exactly ONE render for everyone else.)

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
by that margin. A fixed menu does not move with its trigger, so it closes
once that trigger has moved — whichever scroller moved it, the list for a row's
stub or the panel for a door (one capture-phase `scroll` listener on the
document, since scroll does not bubble) — or the window is resized. It asks
whether the trigger MOVED rather than whether something scrolled: at phone
width the document fires scroll events as a click lands that move nothing,
and closing on those shut the menu under the pointer. The bottom prompt keeps the plain anchored
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
- Fix buttons (`connect_next`, `add_resolve_after`, and `settle_connections`, which only re-sorts) are deterministic autocorrects that respond with Turbo Streams to update both the step list and health panel. A step with more than one door gets **no** Fix for `:no_outgoing_transitions`: both fixes write a blank-condition edge, which on a Yes/No Question catches every answer, so one click let a workflow ship with nobody having looked at No. That issue reads "No answers lead anywhere yet" and opens the step's panel instead
- Import handoff: imports with issues redirect to `?health=true` which auto-opens the health panel on builder connect
- Health fetch is separate from autosave because autosave responds with Turbo Streams (HTML), not JSON
