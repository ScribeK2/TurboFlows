import { Controller } from "@hotwired/stimulus"

/**
 * Inline Step Creator Controller
 * 
 * Sprint 3: Navigation & Visual Improvements
 * Provides inline step creation between existing steps.
 * Shows a "+" button between steps that expands to show step type options.
 */
export default class extends Controller {
  static targets = [
    "addButton",
    "typeSelector",
    "insertPoint"
  ]

  static values = {
    afterIndex: Number,
    expanded: { type: Boolean, default: false }
  }

  connect() {
    // Start collapsed
    this.collapse()
  }

  /**
   * Toggle the type selector
   */
  toggle() {
    this.expandedValue = !this.expandedValue
    this.updateState()
  }

  /**
   * Expand to show type options
   */
  expand() {
    this.expandedValue = true
    this.updateState()
  }

  /**
   * Collapse back to just the + button
   */
  collapse() {
    this.expandedValue = false
    this.updateState()
  }

  /**
   * Update UI based on expanded state
   */
  updateState() {
    if (this.hasAddButtonTarget && this.hasTypeSelectorTarget) {
      if (this.expandedValue) {
        this.addButtonTarget.classList.add("is-hidden")
        this.typeSelectorTarget.classList.remove("is-hidden")
        this.typeSelectorTarget.classList.add("is-visible")
      } else {
        this.addButtonTarget.classList.remove("is-hidden")
        this.typeSelectorTarget.classList.add("is-hidden")
      }
    }
  }

  /**
   * Create a new step of the specified type
   */
  createStep(event) {
    const stepType = event.currentTarget.dataset.stepType
    const afterIndex = this.afterIndexValue
    
    // Dispatch event to workflow builder to create the step
    const customEvent = new CustomEvent("inline-step:create", {
      detail: {
        type: stepType,
        afterIndex: afterIndex
      },
      bubbles: true
    })
    this.element.dispatchEvent(customEvent)
    
    // Collapse back
    this.collapse()
  }

  /**
   * Handle click outside to collapse
   */
  clickOutside(event) {
    if (this.expandedValue && !this.element.contains(event.target)) {
      this.collapse()
    }
  }
}

