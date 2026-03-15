import { Controller } from "@hotwired/stimulus"

/**
 * Controller for the transition editor modal.
 * Handles editing conditions and labels for graph transitions.
 */
export default class extends Controller {
  static targets = ["fromStep", "toStep", "condition", "label", "fromStepId", "toStepId"]
  static values = {
    workflowId: Number
  }

  connect() {
    // Listen for transition edit requests
    this.boundOpenEditor = this.openEditor.bind(this)
    document.addEventListener("transition:edit", this.boundOpenEditor)
  }

  disconnect() {
    if (this.boundOpenEditor) {
      document.removeEventListener("transition:edit", this.boundOpenEditor)
    }
  }

  /**
   * Open the transition editor modal with transition data
   */
  openEditor(event) {
    const { fromStepId, fromStepTitle, toStepId, toStepTitle, condition, label } = event.detail

    // Populate the modal
    if (this.hasFromStepTarget) {
      this.fromStepTarget.textContent = fromStepTitle || fromStepId
    }
    if (this.hasToStepTarget) {
      this.toStepTarget.textContent = toStepTitle || toStepId
    }
    if (this.hasConditionTarget) {
      this.conditionTarget.value = condition || ""
    }
    if (this.hasLabelTarget) {
      this.labelTarget.value = label || ""
    }
    if (this.hasFromStepIdTarget) {
      this.fromStepIdTarget.value = fromStepId
    }
    if (this.hasToStepIdTarget) {
      this.toStepIdTarget.value = toStepId
    }

    // Show the modal
    this.element.classList.remove("is-hidden")
  }

  /**
   * Close the transition editor modal
   */
  close() {
    this.element.classList.add("is-hidden")

    // Clear form
    if (this.hasConditionTarget) this.conditionTarget.value = ""
    if (this.hasLabelTarget) this.labelTarget.value = ""
    if (this.hasFromStepIdTarget) this.fromStepIdTarget.value = ""
    if (this.hasToStepIdTarget) this.toStepIdTarget.value = ""
  }

  /**
   * Save the transition changes
   */
  saveTransition() {
    const fromStepId = this.hasFromStepIdTarget ? this.fromStepIdTarget.value : null
    const toStepId = this.hasToStepIdTarget ? this.toStepIdTarget.value : null
    const condition = this.hasConditionTarget ? this.conditionTarget.value.trim() : ""
    const label = this.hasLabelTarget ? this.labelTarget.value.trim() : ""

    if (!fromStepId || !toStepId) {
      console.error("[TransitionEditor] Missing step IDs")
      return
    }

    // Dispatch event to update the transition in the workflow
    document.dispatchEvent(new CustomEvent("transition:update", {
      detail: {
        fromStepId,
        toStepId,
        condition: condition || null,
        label: label || null
      }
    }))

    this.close()

    // Notify preview to update
    document.dispatchEvent(new CustomEvent("workflow:updated"))
  }

  /**
   * Delete the transition
   */
  deleteTransition() {
    const fromStepId = this.hasFromStepIdTarget ? this.fromStepIdTarget.value : null
    const toStepId = this.hasToStepIdTarget ? this.toStepIdTarget.value : null

    if (!fromStepId || !toStepId) {
      console.error("[TransitionEditor] Missing step IDs")
      return
    }

    // Confirm deletion
    if (!confirm("Are you sure you want to delete this transition?")) {
      return
    }

    // Dispatch event to delete the transition
    document.dispatchEvent(new CustomEvent("transition:delete", {
      detail: { fromStepId, toStepId }
    }))

    this.close()

    // Notify preview to update
    document.dispatchEvent(new CustomEvent("workflow:updated"))
  }
}
