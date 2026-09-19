import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"
import { deferSubmitUntilPanelSaved } from "services/pending_panel_saves"

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

    // Closes a door-positioned picker rather than leaving it drift away from
    // the trigger it was placed beside. Bound once here, added/removed from
    // the document and window only while the picker is floating.
    this.boundCloseFloatingPicker = this.closeTypePicker.bind(this)
    this.boundCloseOnScroll = this.closeOnScroll.bind(this)
  }

  disconnect() {
    this.sortable?.destroy()
    document.removeEventListener("click", this.boundCloseOnOutsideClick)
    document.removeEventListener("keydown", this.boundCloseOnEscape, true)
    document.removeEventListener("click", this.boundGrowFromOutside)
    this.detachFloatingCloseListeners()
  }

  // The bottom prompt: a step connected to nothing. Keeps today's anchored
  // behaviour — clear any positioning left over from a door-opened picker.
  toggleTypePicker(event) {
    event.stopPropagation()
    const opening = this.typePickerTarget?.hidden
    if (opening) {
      this.setDoor({})
      this.clearFloatingPosition()
    }
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

  // A grow acts on what the server believes about the step it grows from, and
  // the panel may be holding an edit to that very step - see
  // services/pending_panel_saves for the whole story.
  growAfterPendingSave(event) {
    deferSubmitUntilPanelSaved(this.application, event)
  }

  openForDoor(trigger) {
    this.setDoor({
      from: trigger.dataset.growFrom,
      label: trigger.dataset.growLabel,
      condition: trigger.dataset.growCondition,
      context: trigger.dataset.growContext
    })
    this.setTypePickerHidden(false)
    this.positionPickerNear(trigger)
  }

  // Anchors the picker beside whatever door was pressed instead of always
  // opening off the bottom prompt (a 40-step workflow put row 1's picker
  // ~650px below the row it belonged to). position: fixed escapes
  // .builder__list-scroll's overflow-y clipping, and the size is read AFTER
  // the menu is un-hidden, so its real size is what gets clamped.
  //
  // offsetWidth/offsetHeight, not getBoundingClientRect: the picker enters
  // via @starting-style (transform: scale(0.95), see builder.css), and this
  // runs in the same tick as removing `hidden` - before the browser has
  // painted a frame, so a rect read here is still scaled down (256px measured
  // as ~243px), which threw the clamp off by the same margin. offset* reads
  // the element's own layout box and ignores transforms entirely.
  positionPickerNear(trigger) {
    if (!this.hasTypePickerTarget) return

    const menu = this.typePickerTarget
    const gutter = 8
    menu.classList.add("builder__type-picker--floating")

    const triggerRect = trigger.getBoundingClientRect()
    const menuWidth = menu.offsetWidth
    const menuHeight = menu.offsetHeight

    let top = triggerRect.bottom + gutter
    if (top + menuHeight > window.innerHeight - gutter) {
      top = triggerRect.top - menuHeight - gutter
    }
    top = Math.max(gutter, Math.min(top, window.innerHeight - menuHeight - gutter))

    const left = Math.max(gutter, Math.min(triggerRect.left, window.innerWidth - menuWidth - gutter))

    menu.style.top = `${top}px`
    menu.style.left = `${left}px`

    this.floatingTrigger = trigger
    this.floatingTriggerAt = { top: triggerRect.top, left: triggerRect.left }
    this.attachFloatingCloseListeners()
  }

  // A fixed-position menu doesn't move with whatever it was placed beside, so
  // scrolling or resizing the window closes it rather than leaving it
  // stranded over the wrong thing. Its trigger is a row's stub (the list
  // scrolls) OR a door in the step panel (the panel scrolls on its own, and is
  // not inside this controller's element), so this listens on the document in
  // the CAPTURE phase: scroll does not bubble, but it is captured, which
  // catches every scroller without naming any of them.
  attachFloatingCloseListeners() {
    document.addEventListener("scroll", this.boundCloseOnScroll, true)
    window.addEventListener("resize", this.boundCloseFloatingPicker)
  }

  detachFloatingCloseListeners() {
    document.removeEventListener("scroll", this.boundCloseOnScroll, true)
    window.removeEventListener("resize", this.boundCloseFloatingPicker)
    this.floatingTrigger = null
  }

  // Closes only when the trigger has actually moved (or is gone). A scroll
  // event alone says nothing: the menu's own contents scrolling fires one, and
  // so does a scroll that ends where it began - at phone width the document
  // fires several as a click lands, none of which move the door an inch.
  closeOnScroll() {
    const trigger = this.floatingTrigger
    if (trigger?.isConnected) {
      const rect = trigger.getBoundingClientRect()
      const moved = Math.abs(rect.top - this.floatingTriggerAt.top) > 1 ||
                    Math.abs(rect.left - this.floatingTriggerAt.left) > 1
      if (!moved) return
    }

    this.closeTypePicker()
  }

  clearFloatingPosition() {
    if (!this.hasTypePickerTarget) return

    this.typePickerTarget.classList.remove("builder__type-picker--floating")
    this.typePickerTarget.style.top = ""
    this.typePickerTarget.style.left = ""
    this.detachFloatingCloseListeners()
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
    if (hidden) this.clearFloatingPosition()
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
