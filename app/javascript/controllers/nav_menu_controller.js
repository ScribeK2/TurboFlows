import { Controller } from "@hotwired/stimulus"

// Fizzy-style <dialog> menu controller (non-modal).
// Uses dialog.show() instead of showModal() — no backdrop overlay.
// Click-outside and Escape handled via document listeners.
//
// Usage:
//   <div data-controller="nav-menu" data-nav-menu-src-value="/nav/menu">
//     <button data-action="click->nav-menu#toggle">Menu</button>
//     <dialog data-nav-menu-target="dialog" class="nav__menu popup popup--animated">
//       <turbo-frame id="nav_menu" data-nav-menu-target="frame"></turbo-frame>
//     </dialog>
//   </div>
export default class extends Controller {
  static targets = ["dialog", "frame"]
  static values = { src: String }

  connect() {
    this.clickOutsideHandler = this.clickOutside.bind(this)
    this.keydownHandler = this.handleKeydown.bind(this)
  }

  disconnect() {
    this.#stopListening()
    if (this.hasDialogTarget && this.dialogTarget.open) {
      this.dialogTarget.close()
    }
  }

  toggle() {
    this.dialogTarget.open ? this.close() : this.open()
  }

  open() {
    this.element.dispatchEvent(new CustomEvent("dialog:show", { bubbles: true }))

    if (this.hasFrameTarget && this.hasSrcValue && !this.frameTarget.src) {
      this.frameTarget.src = this.srcValue
    }

    this.dialogTarget.show()
    this.#startListening()

    requestAnimationFrame(() => {
      this.dialogTarget.querySelector("a, button")?.focus()
    })
  }

  close() {
    if (this.dialogTarget.open) {
      this.dialogTarget.close()
    }
    this.#stopListening()
  }

  clickOutside(event) {
    if (!this.element.contains(event.target)) {
      this.close()
    }
  }

  handleKeydown(event) {
    if (event.key === "Escape") this.close()
  }

  // Private

  #startListening() {
    // requestAnimationFrame skips the current click event that triggered open(),
    // preventing the menu from closing on the same frame it opened.
    requestAnimationFrame(() => {
      document.addEventListener("click", this.clickOutsideHandler)
    })
    document.addEventListener("keydown", this.keydownHandler)
  }

  #stopListening() {
    document.removeEventListener("click", this.clickOutsideHandler)
    document.removeEventListener("keydown", this.keydownHandler)
  }
}
