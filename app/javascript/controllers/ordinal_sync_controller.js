import { Controller } from "@hotwired/stimulus"

// Keeps every step number printed OUTSIDE the list in step with the list.
//
// Step numbers are the outline's reading order (StepOutline), so a delete, a
// grow, a rewire - this tab's or a collaborator's - can renumber every step.
// The list is re-rendered each time, but the panel's door rows ("Yes →
// Working · 4"), its "Use existing…" candidates, the health panel's "Step N"
// and View Flow were rendered when they opened. The server can't re-render
// them: it doesn't know which panel another tab has open (QA B-004,
// 2026-09-23). The list always has the current numbers, so this copies them:
// every number outside the list is a [data-step-ordinal="<step uuid>"], and
// each takes the badge of that step's row.
//
// Mounted on the builder root beside outline-fold, and for the same reason:
// the whole #step-list element is replaced by several responses.
export default class extends Controller {
  connect() {
    this.observer = new MutationObserver(() => this.queueSync())
    this.observer.observe(this.element, { childList: true, subtree: true })
    this.sync()
  }

  disconnect() {
    this.observer?.disconnect()
  }

  // Many mutations arrive per render; one pass after them is enough.
  queueSync() {
    if (this.syncQueued) return

    this.syncQueued = true
    queueMicrotask(() => {
      this.syncQueued = false
      this.sync()
    })
  }

  sync() {
    const numbers = new Map()
    this.element.querySelectorAll(".builder__step[data-step-uuid]").forEach(row => {
      const badge = row.querySelector(".builder__step-badge")
      if (badge) numbers.set(row.dataset.stepUuid, badge.textContent.trim())
    })

    this.element.querySelectorAll("[data-step-ordinal]").forEach(label => {
      const number = numbers.get(label.dataset.stepOrdinal)
      // Only when it differs: this observer sees its own writes, and an
      // unconditional write would feed it for ever (see outline-fold).
      if (number && label.textContent !== number) label.textContent = number
    })
  }
}
