import { Controller } from "@hotwired/stimulus"

// "Use existing…" on a door row: a native <dialog> listing the workflow's other
// steps. One dialog serves every door on the panel; opening it writes which door
// it is for - and, for a door already wired, the connection to retarget.
export default class extends Controller {
  static targets = ["dialog", "form", "method", "label", "condition", "heading", "filter", "option", "empty"]

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

    this.filterTarget.value = ""
    this.filter()
    this.dialogTarget.showModal()
    this.filterTarget.focus()
  }

  close() {
    if (this.hasDialogTarget && this.dialogTarget.open) this.dialogTarget.close()
  }

  // The request landed. A success means the connection was made and the panel's
  // fresh copy of this dialog is on its way, so close it. A refusal (422) keeps
  // the dialog open, with the flash saying why, so the author can pick something
  // else without reopening it themselves.
  submitEnded(event) {
    if (event.detail.success) this.close()
  }

  // A click whose target is the <dialog> itself landed on the backdrop.
  backdropClose(event) {
    if (event.target === this.dialogTarget) this.close()
  }

  filter() {
    const query = this.filterTarget.value.trim().toLowerCase()
    let shown = 0
    this.optionTargets.forEach(option => {
      const match = !query || option.dataset.search.includes(query)
      option.classList.toggle("is-hidden", !match)
      if (match) shown++
    })
    this.emptyTarget.classList.toggle("is-hidden", shown > 0)
  }
}
