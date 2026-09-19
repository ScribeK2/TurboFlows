import { Controller } from "@hotwired/stimulus"
import { deferSubmitUntilPanelSaved } from "services/pending_panel_saves"
import { focusWhenReplaced } from "services/focus"

// "Use existing…" on a door row: a native <dialog> listing the workflow's other
// steps. One dialog serves every door on the panel; opening it writes which door
// it is for - and, for a door already wired, the connection to retarget.
export default class extends Controller {
  static targets = ["dialog", "form", "method", "label", "condition", "heading", "filter", "option", "empty", "error"]

  connect() {
    // Turbo snapshots the page as you leave; an open dialog comes back on Back
    // as a non-modal <dialog open> with the page behind it live.
    this.boundClose = this.close.bind(this)
    document.addEventListener("turbo:before-cache", this.boundClose)
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.boundClose)
  }

  open(event) {
    const { label = "", condition = "", transitionUrl = "" } = event.currentTarget.dataset

    this.labelTarget.value = label
    this.conditionTarget.value = condition
    this.formTarget.action = transitionUrl || this.formTarget.dataset.createUrl
    this.methodTarget.value = transitionUrl ? "patch" : "post"
    this.headingTarget.textContent = label ? `“${label}” leads to…` : "This step leads to…"

    // A refused attempt fills this in without reloading the rest of the
    // dialog (see render_refusal); clear it so a fresh open never shows a
    // stale reason for something the author hasn't tried yet.
    this.errorTarget.textContent = ""

    this.filterTarget.value = ""
    this.markGoneOptions()
    this.filter()
    this.dialogTarget.showModal()
    this.filterTarget.focus()
  }

  close() {
    if (this.hasDialogTarget && this.dialogTarget.open) this.dialogTarget.close()
  }

  // The same wait a grow makes: this dialog names a door the panel's pending
  // save may be about to remove. See services/pending_panel_saves.
  pickAfterPendingSave(event) {
    deferSubmitUntilPanelSaved(this.application, event)
  }

  // The request landed. A success means the connection was made and the panel's
  // fresh copy of this dialog is on its way, so close it. A refusal (422) keeps
  // the dialog open, with the flash saying why, so the author can pick something
  // else without reopening it themselves.
  submitEnded(event) {
    if (!event.detail.success) return

    this.close()
    // The doors list is re-rendered by this very response, so the button that
    // opened the dialog is gone and the browser's own restore has nothing to
    // go back to. Without this, focus lands on <body>.
    focusWhenReplaced(".step-doors", { within: this.element })
  }

  // A click whose target is the <dialog> itself landed on the backdrop.
  backdropClose(event) {
    if (event.target === this.dialogTarget) this.close()
  }

  // builder_controller listens for Escape on the document to close the whole
  // panel. Stopping it here leaves the browser's own default action alone -
  // stopPropagation() doesn't cancel that, only preventDefault() would - so
  // the dialog still closes itself natively. Without this, Escape while
  // picking a target closed the panel out from under the author too.
  stopEscape(event) {
    event.stopPropagation()
  }

  // A pick refused because its step is gone re-streams the candidate list
  // (steps/_target_picker_options) into the dialog while it is still open, and
  // fresh options arrive unfiltered - so whatever the author had typed sat
  // above a list it no longer described. Stimulus calls this once per option,
  // so the work is queued once for the whole batch. Nothing to do while the
  // dialog is closed: #open runs both itself.
  optionTargetConnected() {
    if (this.refilterQueued || !this.hasDialogTarget || !this.dialogTarget.open) return

    this.refilterQueued = true
    queueMicrotask(() => {
      this.refilterQueued = false
      if (!this.hasFilterTarget) return

      this.markGoneOptions()
      this.filter()
    })
  }

  // A step this dialog's candidate list was rendered with can be gone by the
  // time it opens - this author deleted another step from the list while a
  // different door's panel state persisted, or a collaborator did. The
  // builder's own rows (data-step-id on .builder__step) are the live truth,
  // updated by every delete's broadcast well before it would ever reach this
  // dialog's own re-render (steps/_target_picker is only re-rendered by
  // Steps::TransitionsController, on a connection made from THIS step - see
  // AGENTS.md). So hide any option whose step no longer has a row, rather
  // than trust this dialog's own copy.
  //
  // This can't help with a step ADDED since the panel rendered: a grow
  // replaces the whole panel, rebuilding this dialog fresh with it, so that
  // gap is only reachable through a collaborator's grow while THIS panel
  // stays open - left for TODOS.md.
  markGoneOptions() {
    this.optionTargets.forEach(option => {
      const gone = !document.querySelector(`.builder__step[data-step-id="${option.dataset.stepId}"]`)
      option.dataset.gone = gone ? "true" : "false"
      option.classList.toggle("is-hidden", gone)
    })
  }

  // A gone option stays hidden regardless of what's typed - and out of the
  // "No step matches." count - rather than reappearing the moment the filter
  // text no longer excludes it.
  filter() {
    const query = this.filterTarget.value.trim().toLowerCase()
    let shown = 0
    this.optionTargets.forEach(option => {
      if (option.dataset.gone === "true") return

      const match = !query || option.dataset.search.includes(query)
      option.classList.toggle("is-hidden", !match)
      if (match) shown++
    })
    this.emptyTarget.classList.toggle("is-hidden", shown > 0)
  }
}
