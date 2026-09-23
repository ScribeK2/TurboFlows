import { Controller } from "@hotwired/stimulus"

// Folded exit branches in the builder's outline, kept across re-renders.
//
// Mounted on the builder root, not the list: the transitions endpoint, a
// delete and a health fix replace the whole #step-list element, which would
// discard a controller living on it and every fold with it.
//
// The author's folds are recorded from clicks on a fold's <summary> (keyboard
// activation fires click too), never from `toggle`: toggle fires
// asynchronously, so a restore made here would come back as if the author had
// done it. The branch holding the step whose panel is open is shown when that
// panel opens, and again after a list re-render, without forgetting that the
// author folded it. Between those, a fold the author makes by hand sticks: the
// reveal used to run on every mutation, so the next keystroke in the panel
// (the save indicator's text changing) sprang the branch open again (QA C-001).
//
// The Collapse all/Expand all LABEL is a different matter: it only reads the
// DOM's current `open` state, never records anything, so deriving it from
// `toggle` does not run afoul of that rule. It has to be `toggle`, and it has
// to be capture: a trusted click's activation behaviour (the browser flipping
// `<details>.open`) runs AFTER `clicked()` below returns, so a microtask
// queued from inside `clicked()` still sees the state being LEFT, not the one
// being entered - a scripted `.click()` doesn't show this, because it runs
// its microtask checkpoint after the flip, which is why this shipped once
// already. `toggle` does not bubble, so a bubble-phase listener on the root
// never sees it; capture does. Never compute the label from `this.closed`
// either: `this.revealed` holds a fold open without discarding its entry there.
export default class extends Controller {
  static targets = ["toggleAll"]

  connect() {
    this.closed = new Set()
    this.revealed = new Set()
    this.boundClick = this.clicked.bind(this)
    this.element.addEventListener("click", this.boundClick)
    this.boundToggle = () => this.updateToggleAll()
    this.element.addEventListener("toggle", this.boundToggle, true)

    this.observer = new MutationObserver(() => this.queueReapply())
    this.observer.observe(this.element, { childList: true, subtree: true })
    this.reapply()
  }

  disconnect() {
    this.element.removeEventListener("click", this.boundClick)
    this.element.removeEventListener("toggle", this.boundToggle, true)
    this.observer?.disconnect()
  }

  clicked(event) {
    const summary = event.target.closest("summary")
    const details = summary?.parentElement
    if (!(details instanceof HTMLDetailsElement) || !details.dataset.foldKey) return
    if (details.firstElementChild !== summary) return

    // The click runs before the browser flips `open`: the state now is the
    // state being left. The label itself is refreshed by the capture-phase
    // `toggle` listener above, once the flip has actually happened.
    if (details.open) {
      this.closed.add(details.dataset.foldKey)
      this.revealed.delete(details.dataset.foldKey)
    } else {
      this.closed.delete(details.dataset.foldKey)
    }
  }

  toggleAll() {
    const folds = this.folds()
    const expanding = folds.some(details => !details.open)
    this.closed = expanding ? new Set() : new Set(folds.map(details => details.dataset.foldKey))
    this.reapply()
  }

  // Many mutations arrive per render; one pass after them is enough.
  queueReapply() {
    if (this.reapplyQueued) return

    this.reapplyQueued = true
    queueMicrotask(() => {
      this.reapplyQueued = false
      this.reapply()
    })
  }

  reapply() {
    this.updateRevealed()
    this.folds().forEach(details => {
      const key = details.dataset.foldKey
      const open = !this.closed.has(key) || this.revealed.has(key)
      if (details.open !== open) details.open = open
    })
    this.updateToggleAll()
  }

  // Which folds are held open for the open step: those around its row, worked
  // out afresh only when the open step changes or the outline itself was
  // replaced (both update("steps-list") and replace("step-list") render a
  // fresh .builder__outline; a save indicator's text or one row's replacement
  // do not). Between those, reapply keeps the set as it is, so a fold the
  // author closes by hand (clicked() drops it from the set) stays closed.
  updateRevealed() {
    const stepId = this.element.querySelector("#builder-panel .builder__panel-body[data-step-id]")?.dataset.stepId
    const outline = this.element.querySelector(".builder__outline")
    if (stepId === this.revealedStepId && outline === this.revealedOutline) return

    this.revealedStepId = stepId
    this.revealedOutline = outline
    this.revealed = new Set()
    if (!stepId) return

    const row = this.element.querySelector(`.builder__step[data-step-id="${CSS.escape(stepId)}"]`)
    for (let fold = row?.closest("details[data-fold-key]"); fold; fold = fold.parentElement?.closest("details[data-fold-key]")) {
      this.revealed.add(fold.dataset.foldKey)
    }
  }

  updateToggleAll() {
    if (!this.hasToggleAllTarget) return

    // Writing textContent unconditionally is a childList mutation on the
    // observed subtree, which re-fires the observer, which calls back in
    // here forever. Write only when the value actually changes.
    const folds = this.folds()
    const hidden = folds.length === 0
    const label = folds.some(details => !details.open) ? "Expand all" : "Collapse all"
    if (this.toggleAllTarget.hidden !== hidden) this.toggleAllTarget.hidden = hidden
    if (this.toggleAllTarget.textContent !== label) this.toggleAllTarget.textContent = label
  }

  folds() {
    return [...this.element.querySelectorAll("details[data-fold-key]")]
  }
}
