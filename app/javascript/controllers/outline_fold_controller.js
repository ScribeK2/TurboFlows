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
// done it. The branch holding the step whose panel is open is always shown,
// without forgetting that the author folded it.
export default class extends Controller {
  static targets = ["toggleAll"]

  connect() {
    this.closed = new Set()
    this.boundClick = this.clicked.bind(this)
    this.element.addEventListener("click", this.boundClick)

    this.observer = new MutationObserver(() => this.queueReapply())
    this.observer.observe(this.element, { childList: true, subtree: true })
    this.reapply()
  }

  disconnect() {
    this.element.removeEventListener("click", this.boundClick)
    this.observer?.disconnect()
  }

  clicked(event) {
    const summary = event.target.closest("summary")
    const details = summary?.parentElement
    if (!(details instanceof HTMLDetailsElement) || !details.dataset.foldKey) return
    if (details.firstElementChild !== summary) return

    // The click runs before the browser flips `open`: the state now is the
    // state being left.
    if (details.open) this.closed.add(details.dataset.foldKey)
    else this.closed.delete(details.dataset.foldKey)
    queueMicrotask(() => this.updateToggleAll())
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
    this.folds().forEach(details => {
      const open = !this.closed.has(details.dataset.foldKey)
      if (details.open !== open) details.open = open
    })
    this.revealOpenStep()
    this.updateToggleAll()
  }

  revealOpenStep() {
    const stepId = this.element.querySelector("#builder-panel .builder__panel-body[data-step-id]")?.dataset.stepId
    if (!stepId) return

    const row = this.element.querySelector(`.builder__step[data-step-id="${CSS.escape(stepId)}"]`)
    for (let fold = row?.closest("details[data-fold-key]"); fold; fold = fold.parentElement?.closest("details[data-fold-key]")) {
      if (!fold.open) fold.open = true
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
