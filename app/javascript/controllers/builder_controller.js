import { Controller } from "@hotwired/stimulus"

// The step panel's inline-autosave waits this long after the last keystroke;
// the header title matches it, so the two fields behave the same way.
const TITLE_SAVE_DEBOUNCE = 2000

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
    document.removeEventListener("keydown", this.boundKeydown)
    document.removeEventListener("turbo:before-stream-render", this.boundWrapStreamRender)
    document.removeEventListener("turbo:frame-load", this.boundOnPanelFrameLoad)
    this.clearTitleSave()
  }

  // See the connect() comment above: this stays a document listener so it
  // survives #builder-panel being replaced wholesale.
  onPanelFrameLoad(event) {
    if (event.target.id === "builder-panel") this.syncSelectedRow()
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
      this.closePanel()
      this.closedOnMissingRowOf = panelBody.dataset.stepId
      return
    }
    row.classList.add("builder__step--selected")
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

  rowFor(stepId) {
    return this.element.querySelector(`.builder__step[data-step-id="${stepId}"]`)
  }

  openStep(event) {
    const url = event.currentTarget.dataset.builderUrlParam
    if (!url) return

    event.preventDefault()
    event.stopPropagation()

    this.element.querySelectorAll(".builder__step--selected").forEach(el => {
      el.classList.remove("builder__step--selected")
    })
    event.currentTarget.classList.add("builder__step--selected")

    this.loadPanel(url)
  }

  // A row with more doors than fit on one line: open its panel at the doors.
  openStepAtDoors(event) {
    const row = event.currentTarget.closest(".builder__step")
    const url = event.currentTarget.dataset.builderUrlParam
    if (!row || !url) return

    event.preventDefault()
    event.stopPropagation()
    this.clearSelectedRow()
    row.classList.add("builder__step--selected")

    this.panelTarget.addEventListener("turbo:frame-load", () => {
      this.panelTarget.querySelector(".step-doors")?.scrollIntoView({ block: "center" })
    }, { once: true })
    this.loadPanel(url)
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

    if (this.hasPanelTarget) {
      this.panelTarget.removeAttribute("src")
      while (this.panelTarget.firstChild) {
        this.panelTarget.removeChild(this.panelTarget.firstChild)
      }
    }
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
  }

  handleKeydown(event) {
    if (event.key === "Escape" && this.panelOpen) {
      this.closePanel()
    }
  }
}
