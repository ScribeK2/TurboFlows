import { Controller } from "@hotwired/stimulus"

// Simple controller for native <dialog> elements.
// Usage:
//   <div data-controller="dialog">
//     <button data-action="dialog#open">Open</button>
//     <dialog data-dialog-target="dialog">...</dialog>
//   </div>
export default class extends Controller {
  static targets = ["dialog"]

  open() {
    this.dialogTarget.showModal()
  }

  close() {
    this.dialogTarget.close()
  }
}
