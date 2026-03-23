import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

// Manages the step list: SortableJS drag-and-drop and type picker popover.
export default class extends Controller {
  static targets = ["list", "typePicker"]
  static values = {
    reorderUrl: String
  }

  connect() {
    if (this.hasListTarget) {
      this.sortable = new Sortable(this.listTarget, {
        handle: ".drag-handle",
        animation: 150,
        ghostClass: "builder__list-row--dragging",
        onEnd: this.handleReorder.bind(this)
      })
    }

    this.boundCloseOnOutsideClick = this.closeOnOutsideClick.bind(this)
    document.addEventListener("click", this.boundCloseOnOutsideClick)
  }

  disconnect() {
    this.sortable?.destroy()
    document.removeEventListener("click", this.boundCloseOnOutsideClick)
  }

  toggleTypePicker(event) {
    event.stopPropagation()
    if (this.hasTypePickerTarget) {
      this.typePickerTarget.hidden = !this.typePickerTarget.hidden
    }
  }

  closeTypePicker() {
    if (this.hasTypePickerTarget) {
      this.typePickerTarget.hidden = true
    }
  }

  handleReorder(event) {
    const stepId = event.item.dataset.stepId
    const newPosition = event.newIndex
    const url = this.reorderUrlValue.replace(":id", stepId)

    const token = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(url, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": token
      },
      body: JSON.stringify({ position: newPosition })
    })
  }

  stopPropagation(event) {
    event.stopPropagation()
  }

  closeOnOutsideClick(event) {
    if (this.hasTypePickerTarget && !this.typePickerTarget.hidden) {
      if (!event.target.closest(".builder__list-add-wrapper")) {
        this.typePickerTarget.hidden = true
      }
    }
  }
}
