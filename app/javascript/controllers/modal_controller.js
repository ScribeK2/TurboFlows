import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="modal"
export default class extends Controller {
  static targets = ["backdrop", "content"]

  connect() {
    // Close on Escape key
    this.boundHandleEscape = this.handleEscape.bind(this)
    document.addEventListener("keydown", this.boundHandleEscape)
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundHandleEscape)
  }

  show() {
    this.element.classList.remove("is-hidden")
    document.body.style.overflow = "hidden"
  }

  close() {
    this.element.classList.add("is-hidden")
    document.body.style.overflow = ""
  }

  toggle() {
    if (this.element.classList.contains("is-hidden")) {
      this.show()
    } else {
      this.close()
    }
  }

  backdropClick(event) {
    // Only close if clicking directly on the backdrop (not on content)
    if (event.target === this.backdropTarget) {
      this.close()
    }
  }

  handleEscape(event) {
    if (event.key === "Escape") {
      this.close()
    }
  }

  // Stop event propagation when clicking inside modal content
  stop(event) {
    event.stopPropagation()
  }
}
