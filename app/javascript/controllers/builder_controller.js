import { Controller } from "@hotwired/stimulus"
import { revealRowInList } from "services/scroll"
import { flashAlert } from "services/flash"

// The step panel's inline-autosave waits this long after the last keystroke;
// the header title matches it, so the two fields behave the same way.
const TITLE_SAVE_DEBOUNCE = 2000

// builder.css's one-column breakpoint: below it the open panel takes the
// list's place in the page instead of sitting beside it.
const ONE_COLUMN = "(max-width: 640px)"

// How long a panel closed on a missing row waits before saying its step was
// removed - long enough for a row lost to a broadcast race to come back.
const REMOVED_STEP_REPORT_DELAY = 1000

// Manages the builder shell: panel open/close, mode toggle, keyboard shortcuts.
export default class extends Controller {
  static targets = ["panel", "titleInput"]
  static values = {
    mode: { type: String, default: "view" },
    workflowId: Number
  }

  connect() {
    this.boundKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.boundKeydown)

    // Which step THIS tab is deleting, so #syncSelectedRow can tell the
    // author's own delete of the open step (no message) from someone else's.
    this.boundNoteOwnDelete = this.noteOwnDelete.bind(this)
    this.element.addEventListener("turbo:submit-start", this.boundNoteOwnDelete)

    // Which row is selected is decided here, once, from the open panel — not
    // by the server. A Turbo Stream response (create, a broadcast, a health
    // fix) can repaint #steps-list at any time, including moments after this
    // controller's own request painted a row selected; re-deriving it after
    // every render is what keeps the two from racing. Two paths repaint the
    // panel: a Turbo Stream response replacing #builder-panel (wrapped here),
    // and turbo-frame navigation via loadPanel setting .src (caught below).
    this.boundWrapStreamRender = this.wrapStreamRender.bind(this)
    document.addEventListener("turbo:before-stream-render", this.boundWrapStreamRender)

    // Bound on document, not the panel target: StepsController#create's
    // grown_streams REPLACES #builder-panel wholesale (a fresh <turbo-frame>
    // from steps/panel_edit), so a listener attached to the target node at
    // connect() time ends up on a detached element after the first grow.
    // Filtering by event.target.id keeps this scoped to the one frame.
    this.boundOnPanelFrameLoad = this.onPanelFrameLoad.bind(this)
    document.addEventListener("turbo:frame-load", this.boundOnPanelFrameLoad)

    const params = new URLSearchParams(window.location.search)
    if (params.get("health") === "true") {
      requestAnimationFrame(() => this.openHealth())
    }
  }

  disconnect() {
    this.element.removeEventListener("turbo:submit-start", this.boundNoteOwnDelete)
    document.removeEventListener("keydown", this.boundKeydown)
    document.removeEventListener("turbo:before-stream-render", this.boundWrapStreamRender)
    document.removeEventListener("turbo:frame-load", this.boundOnPanelFrameLoad)
    this.clearTitleSave()
  }

  // See the connect() comment above: this stays a document listener so it
  // survives #builder-panel being replaced wholesale.
  onPanelFrameLoad(event) {
    if (event.target.id !== "builder-panel") return

    this.syncSelectedRow()
    // A jump's target row, looked at again now the panel is in: opening it
    // narrows the list and re-wraps the rows above (see #openStep).
    // Found by id: a list broadcast may have replaced the row since.
    const row = this.stepToReveal && this.rowFor(this.stepToReveal)
    if (row) revealRowInList(row, { block: "center" })
    this.stepToReveal = null

    // In one column the panel replaces the list where the page is, and the
    // page kept its scroll: a step tapped low in a long list opened with its
    // header and Close above the screen (QA C-007). Start it at its top.
    // The frame itself is display: contents - no box, so scrolling it does
    // nothing; its .builder__panel wrapper has one.
    if (this.oneColumn) this.panelTarget.closest(".builder__panel")?.scrollIntoView({ block: "start" })
  }

  // Composes with any other turbo:before-stream-render listener (e.g.
  // step-warnings#onStreamRender, which only reads the event and never
  // touches event.detail.render): each wrapper must call the render it
  // found, never replace it with a fresh one. The render can be async, so
  // this awaits it before re-deriving selection from the panel it just drew.
  wrapStreamRender(event) {
    const original = event.detail.render
    event.detail.render = async streamElement => {
      await original(streamElement)
      this.syncSelectedRow()
    }
  }

  // The one place selection is read back: clear every row, then look at
  // whichever step panel is currently open (its body carries data-step-id —
  // see steps/_panel_edit.html.erb) and select that row. A non-step panel
  // (health, settings, flow diagram) has no such element, so nothing is
  // selected, which is right.
  //
  // Finding 4: an open step panel whose step has no row any more - deleted
  // from the list, by this author or a collaborator - closes rather than
  // sitting on a dead step. Its autosave form targets _top, so its next PATCH
  // would 404 the WHOLE page rather than answer inside the frame. This runs
  // after every stream that can replace the list, so it is also what notices
  // the deletion: destroy's own response never mentions the panel unless
  // deleting the step emptied the list entirely (destroy_streams clears it
  // itself then) - this covers the ordinary case, where other steps remain.
  //
  // A missing row does not always mean a deleted step. A list broadcast is
  // rendered from a read taken when it is SENT, so one another editor's request
  // rendered before this author's grow committed can arrive after the grow's
  // own response - and for that moment the new step has no row. Nothing here
  // can tell that from a delete, and guessing "stale" would leave a panel open
  // on a dead step, so the panel still closes at once. What it does instead is
  // remember which step it closed on: if a later render brings that row back
  // while no other panel has been opened, the panel reopens. A deleted step's
  // row never comes back, so for a delete this changes nothing.
  syncSelectedRow() {
    this.clearSelectedRow()
    this.reopenPanelIfRowReturned()

    const panelBody = this.hasPanelTarget
      ? this.panelTarget.querySelector(".builder__panel-body[data-step-id]")
      : null
    if (!panelBody) return

    const row = this.rowFor(panelBody.dataset.stepId)
    if (!row) {
      const stepId = panelBody.dataset.stepId
      const hadFocus = this.panelTarget.contains(document.activeElement)
      this.closePanel()
      this.closedOnMissingRowOf = stepId
      this.reportClosedStep(stepId, hadFocus)
      return
    }
    row.classList.add("builder__step--selected")
    row.closest("[role='treeitem']")?.setAttribute("aria-selected", "true")
  }

  // Before the panel is looked at, so this render's own row can reopen it. The
  // URL comes from the returned row - a grown step's panel arrived by stream,
  // so the frame never had a src to remember.
  reopenPanelIfRowReturned() {
    const stepId = this.closedOnMissingRowOf
    if (!stepId) return

    if (this.panelOpen) {
      this.closedOnMissingRowOf = null
      return
    }

    const url = this.rowFor(stepId)?.dataset.builderUrlParam
    if (url) this.loadPanel(url)
  }

  // The panel closed because its step's row is gone. It used to vanish
  // mid-typing without a word, focus dropping to <body> (QA C-005). Say why -
  // unless this tab deleted the step itself, which needs no telling - and put
  // focus back in the list if it was in the panel.
  //
  // The message waits a moment: a row can also go missing for an instant in a
  // broadcast race (see above), and then the panel reopens by itself - it must
  // not claim a deletion. Only if the step is still the one closed on, and
  // still has no row, is it reported.
  reportClosedStep(stepId, hadFocus) {
    const someoneElse = this.ownDeleteOf !== stepId
    this.ownDeleteOf = null
    if (hadFocus) this.element.querySelector('#steps-list [role="treeitem"]')?.focus()
    if (!someoneElse) return

    setTimeout(() => {
      if (this.closedOnMissingRowOf === stepId && !this.rowFor(stepId)) {
        flashAlert("The step you had open was removed by someone else, so its panel closed.")
      }
    }, REMOVED_STEP_REPORT_DELAY)
  }

  noteOwnDelete(event) {
    const form = event.target
    if (!form.querySelector?.('input[name="_method"][value="delete"]')) return

    const row = form.closest(".builder__step")
    if (row) this.ownDeleteOf = row.dataset.stepId
  }

  rowFor(stepId) {
    return this.element.querySelector(`.builder__step[data-step-id="${stepId}"]`)
  }

  openStep(event) {
    const url = event.currentTarget.dataset.builderUrlParam
    if (!url) return

    event.preventDefault()
    event.stopPropagation()

    // A jump chip opens ANOTHER step, whose row is the one selected, not the chip.
    this.clearSelectedRow()
    const row = event.currentTarget.matches(".builder__step")
      ? event.currentTarget
      : this.rowFor(event.params.stepId)
    row?.classList.add("builder__step--selected")
    row?.closest("[role='treeitem']")?.setAttribute("aria-selected", "true")

    // A jump is the outline's "go to": its target can be far down the list, or
    // inside a folded branch (QA C-002). outline-fold owns every fold's `open`,
    // so ask it to reveal the row's branch (synchronously), then bring the row
    // into view, centred, since the panel opening will re-wrap the rows.
    this.loadPanel(url)
    // After loadPanel, which clears it for every other caller.
    if (row && row !== event.currentTarget) {
      this.dispatch("reveal", { prefix: "outline-fold", detail: { stepId: row.dataset.stepId } })
      revealRowInList(row, { block: "center" })
      this.stepToReveal = row.dataset.stepId
    }
  }

  openFlowDiagram() {
    const url = this.element.querySelector("[data-builder-flow-url-value]")
      ?.dataset.builderFlowUrlValue
    if (url) {
      this.clearSelectedRow()
      this.loadPanel(url)
    }
  }

  openSettings() {
    const url = this.element.querySelector("[data-builder-settings-url-value]")
      ?.dataset.builderSettingsUrlValue
    if (url) {
      this.clearSelectedRow()
      this.loadPanel(url)
    }
  }

  openHealth() {
    const url = this.element.dataset.builderHealthUrlValue
    if (url) {
      this.clearSelectedRow()
      this.loadPanel(url)
    }
  }

  closePanel() {
    this.clearSelectedRow()
    // An author's own close is final; #syncSelectedRow sets this again AFTER
    // calling here when the close was its own.
    this.closedOnMissingRowOf = null
    this.stepToReveal = null

    if (this.hasPanelTarget) {
      this.panelTarget.removeAttribute("src")
      while (this.panelTarget.firstChild) {
        this.panelTarget.removeChild(this.panelTarget.firstChild)
      }
    }

    // In one column, closing puts the list back: return to where the author
    // was in it when the panel took its place (see #loadPanel).
    if (this.listScrollY != null && this.oneColumn) window.scrollTo(0, this.listScrollY)
    this.listScrollY = null
  }

  get oneColumn() {
    return window.matchMedia(ONE_COLUMN).matches
  }

  // Whether the panel is open, read from the same fact the CSS uses: does the
  // frame have content. Nothing has to remember to set a flag, so no injection
  // path can leave the two disagreeing.
  get panelOpen() {
    return this.hasPanelTarget && this.panelTarget.children.length > 0
  }

  // blur and change save at once: the author has finished with the field.
  saveTitle(event) {
    this.clearTitleSave()
    this.submitTitle(event.currentTarget)
  }

  // Typing saves too, on the same debounce every other builder field uses. The
  // title used to save on blur and change ALONE, so a rename the author typed
  // and then walked away from — to a step row, which does not always take focus
  // out of the header — was dropped with nothing said.
  scheduleTitleSave(event) {
    const input = event.currentTarget
    this.clearTitleSave()
    this.titleSaveTimer = setTimeout(() => this.submitTitle(input), TITLE_SAVE_DEBOUNCE)
  }

  clearTitleSave() {
    if (this.titleSaveTimer) clearTimeout(this.titleSaveTimer)
    this.titleSaveTimer = null
  }

  submitTitle(input) {
    if (this.modeValue !== "edit") return
    if (!input) return

    const url = input.dataset.url
    const title = input.value.trim()

    if (!title || !url) return

    const token = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(url, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": token,
        "Accept": "application/json"
      },
      body: JSON.stringify({ workflow: { title } })
    }).then(async response => {
      const statusEl = document.getElementById("autosave-status")
      if (!statusEl) return

      if (response.ok) {
        statusEl.textContent = "Saved"
        statusEl.className = "builder__autosave builder__autosave--saved"
        return
      }

      // The JSON error body carries the reason. Details shows it through its
      // Turbo Stream partial; a bare "Save failed" here left the author guessing.
      const body = await response.json().catch(() => ({}))
      const reason = Array.isArray(body.errors) ? body.errors[0] : null
      statusEl.textContent = reason ? `Save failed — ${reason}` : "Save failed"
      statusEl.className = "builder__autosave builder__autosave--error"
    })
  }

  // In view mode every panel is a preview, whatever the person may do: the
  // server decides readonly from this flag or from permission, so a row
  // rendered by a broadcast (which knows no mode) still opens as a preview.
  loadPanel(url) {
    if (!this.hasPanelTarget) return

    // Whatever opens a panel - the author or the reopen itself - ends the wait
    // for a row to come back (see #syncSelectedRow).
    this.closedOnMissingRowOf = null
    // And any jump's pending second look (see #openStep): a health, settings
    // or flow panel loaded after a jump must not scroll to the jump's row.
    this.stepToReveal = null
    // Opening over the list (not moving from one panel to another): remember
    // where the page was, for #closePanel to come back to.
    if (!this.panelOpen) this.listScrollY = window.scrollY

    this.panelTarget.src = this.modeValue === "edit" ? url : this.readonlyUrl(url)
  }

  readonlyUrl(url) {
    const resolved = new URL(url, window.location.origin)
    resolved.searchParams.set("readonly", "1")
    return resolved.pathname + resolved.search
  }

  clearSelectedRow() {
    this.element.querySelectorAll(".builder__step--selected").forEach(el => {
      el.classList.remove("builder__step--selected")
    })
    this.element.querySelectorAll("[role='treeitem'][aria-selected]").forEach(el => el.removeAttribute("aria-selected"))
  }

  handleKeydown(event) {
    if (event.key === "Escape" && this.panelOpen) {
      this.closePanel()
    }
  }
}
