import { Controller } from "@hotwired/stimulus"

// Fizzy-style <dialog> menu controller.
// Wraps a trigger button and a <dialog> element.
// Lazy-loads Turbo Frame content on first open.
//
// Usage:
//   <div data-controller="nav-menu" data-nav-menu-src-value="/nav/menu">
//     <button data-action="click->nav-menu#toggle">Menu</button>
//     <dialog data-nav-menu-target="dialog">
//       <turbo-frame id="nav_menu" data-nav-menu-target="frame"></turbo-frame>
//     </dialog>
//   </div>
export default class extends Controller {
  static targets = ["dialog", "frame"]
  static values = { src: String }

  toggle() {
    if (this.dialogTarget.open) {
      this.close()
    } else {
      this.open()
    }
  }

  open() {
    // Dispatch event for dialog manager to close other dialogs
    this.element.dispatchEvent(new CustomEvent("dialog:show", { bubbles: true }))

    // Lazy-load Turbo Frame content on first open
    if (this.hasFrameTarget && this.hasSrcValue && !this.frameTarget.src) {
      this.frameTarget.src = this.srcValue
    }

    this.dialogTarget.showModal()
  }

  close() {
    if (this.dialogTarget.open) {
      this.dialogTarget.close()
    }
  }

  // Close on backdrop click (click target is the dialog element itself when clicking backdrop)
  backdropClose(event) {
    if (event.target === this.dialogTarget) {
      this.close()
    }
  }
}
