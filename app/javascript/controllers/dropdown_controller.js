import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu"]

  connect() {
    this.closeOnOutsideClick = this.closeOnOutsideClick.bind(this)
    this.closeOnEscape = this.closeOnEscape.bind(this)
  }

  toggle() {
    if (this.menuTarget.classList.contains("is-hidden")) {
      this.open()
    } else {
      this.close()
    }
  }

  open() {
    this.menuTarget.classList.remove("is-hidden")
    this.menuTarget.classList.add("is-open")
    // Update aria
    this.element.querySelector("[aria-expanded]").setAttribute("aria-expanded", "true")
    // Listen for outside clicks and escape
    document.addEventListener("click", this.closeOnOutsideClick)
    document.addEventListener("keydown", this.closeOnEscape)
  }

  close() {
    this.menuTarget.classList.remove("is-open")
    // Wait for animation to finish before hiding
    setTimeout(() => {
      this.menuTarget.classList.add("is-hidden")
    }, 150)
    // Update aria
    this.element.querySelector("[aria-expanded]").setAttribute("aria-expanded", "false")
    // Remove listeners
    document.removeEventListener("click", this.closeOnOutsideClick)
    document.removeEventListener("keydown", this.closeOnEscape)
  }

  closeOnOutsideClick(event) {
    if (!this.element.contains(event.target)) {
      this.close()
    }
  }

  closeOnEscape(event) {
    if (event.key === "Escape") {
      this.close()
    }
  }

  disconnect() {
    document.removeEventListener("click", this.closeOnOutsideClick)
    document.removeEventListener("keydown", this.closeOnEscape)
  }
}
