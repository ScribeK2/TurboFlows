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
        ghostClass: "sortable-ghost",
        dragClass: "sortable-drag",
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
    this.setTypePickerHidden(!this.typePickerTarget?.hidden)
  }

  closeTypePicker() {
    this.setTypePickerHidden(true)
  }

  // The picker is a .dropdown__menu, and that component is driven by
  // .is-hidden, not the hidden attribute - utilities.css carries
  // `.dropdown__menu:not(.is-hidden) { display: block }`, which sits in the
  // utilities layer and so outranks anything components can say. Keep the
  // attribute in sync too, so the element stays semantically hidden.
  setTypePickerHidden(hidden) {
    if (!this.hasTypePickerTarget) return

    this.typePickerTarget.hidden = hidden
    this.typePickerTarget.classList.toggle("is-hidden", hidden)
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

  // The picker lives inside .builder__list-add-wrapper, so a click on one of
  // its options counts as "inside" and must not be treated as an outside click.
  // Choosing a type closes it explicitly, via closeTypePicker.
  closeOnOutsideClick(event) {
    if (this.hasTypePickerTarget && !this.typePickerTarget.hidden) {
      if (!event.target.closest(".builder__list-add-wrapper")) {
        this.setTypePickerHidden(true)
      }
    }
  }
}
