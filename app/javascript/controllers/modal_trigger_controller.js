import { Controller } from "@hotwired/stimulus"

// Opens/closes a modal by element ID from outside the modal controller's scope.
// Usage: data-controller="modal-trigger" data-modal-trigger-modal-id-value="my-modal"
//        data-action="click->modal-trigger#open"
export default class extends Controller {
  static values = { modalId: String }

  open() {
    const modal = document.getElementById(this.modalIdValue)
    if (modal) {
      modal.classList.remove("is-hidden")
      document.body.style.overflow = "hidden"
    }
  }

  close() {
    const modal = document.getElementById(this.modalIdValue)
    if (modal) {
      modal.classList.add("is-hidden")
      document.body.style.overflow = ""
    }
  }
}
