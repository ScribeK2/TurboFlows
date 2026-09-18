import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

// Manages the step list: SortableJS drag-and-drop and type picker popover.
export default class extends Controller {
  static targets = ["list", "typePicker", "pickerContext", "fromStepId", "doorLabel", "doorCondition"]
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

    // Capture phase, so this runs before the builder's own document keydown
    // handler and can stop it: Escape with the picker open closes the picker,
    // not the panel behind it.
    this.boundCloseOnEscape = this.closeOnEscape.bind(this)
    document.addEventListener("keydown", this.boundCloseOnEscape, true)

    // Door buttons in the step panel sit outside this controller's element.
    this.boundGrowFromOutside = this.growFromOutside.bind(this)
    document.addEventListener("click", this.boundGrowFromOutside)
  }

  disconnect() {
    this.sortable?.destroy()
    document.removeEventListener("click", this.boundCloseOnOutsideClick)
    document.removeEventListener("keydown", this.boundCloseOnEscape, true)
    document.removeEventListener("click", this.boundGrowFromOutside)
  }

  // The bottom prompt: a step connected to nothing.
  toggleTypePicker(event) {
    event.stopPropagation()
    const opening = this.typePickerTarget?.hidden
    if (opening) this.setDoor({})
    this.setTypePickerHidden(!opening)
  }

  closeTypePicker() {
    this.setTypePickerHidden(true)
  }

  // A row's own button. Stop the click reaching the row, which opens the panel.
  growFromDoor(event) {
    event.preventDefault()
    event.stopPropagation()
    this.openForDoor(event.currentTarget)
  }

  growFromOutside(event) {
    const trigger = event.target.closest("[data-grow-from]")
    if (!trigger || this.element.contains(trigger)) return

    event.preventDefault()
    this.openForDoor(trigger)
  }

  openForDoor(trigger) {
    this.setDoor({
      from: trigger.dataset.growFrom,
      label: trigger.dataset.growLabel,
      condition: trigger.dataset.growCondition,
      context: trigger.dataset.growContext
    })
    this.setTypePickerHidden(false)
  }

  // Written when the picker OPENS, never when it closes: choosing a type closes
  // the picker on click, before the form submits, and clearing here would send
  // the grow with no parent.
  setDoor({ from = "", label = "", condition = "", context = "" }) {
    this.fromStepIdTargets.forEach(field => { field.value = from })
    this.doorLabelTargets.forEach(field => { field.value = label })
    this.doorConditionTargets.forEach(field => { field.value = condition })
    if (this.hasPickerContextTarget) {
      this.pickerContextTarget.textContent = context
      this.pickerContextTarget.hidden = !context
    }
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
  closeOnEscape(event) {
    if (event.key !== "Escape") return
    if (!this.hasTypePickerTarget || this.typePickerTarget.hidden) return

    this.setTypePickerHidden(true)
    event.stopPropagation()
  }

  closeOnOutsideClick(event) {
    if (this.hasTypePickerTarget && !this.typePickerTarget.hidden) {
      if (!event.target.closest(".builder__list-add-wrapper") && !event.target.closest("[data-grow-from]")) {
        this.setTypePickerHidden(true)
      }
    }
  }
}
