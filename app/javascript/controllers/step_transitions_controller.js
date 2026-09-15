import { Controller } from "@hotwired/stimulus"

/**
 * Step Transitions Controller
 *
 * Manages the connections/transitions UI for graph mode workflows.
 * Each step can have multiple transitions to other steps, with optional conditions.
 */
export default class extends Controller {
  static targets = ["transitionsList", "hiddenInput", "rowTemplate", "emptyTemplate"]
  static values = {
    stepId: String,
    stepIndex: Number,
    variables: Array
  }

  connect() {
    this.refresh()
  }

  /**
   * Refresh and re-render transitions
   */
  refresh() {
    this.transitions = this.loadTransitions()
    this.renderTransitions()
  }

  /**
   * Load transitions from the hidden input
   */
  loadTransitions() {
    if (this.hasHiddenInputTarget && this.hiddenInputTarget.value) {
      try {
        return JSON.parse(this.hiddenInputTarget.value)
      } catch (e) {
        console.error('[StepTransitions] Failed to parse transitions:', e)
        return []
      }
    }
    return []
  }

  /**
   * Save transitions to the hidden input
   */
  saveTransitions() {
    if (this.hasHiddenInputTarget) {
      this.hiddenInputTarget.value = JSON.stringify(this.transitions)
      // Trigger autosave by dispatching input event on the hidden field
      this.hiddenInputTarget.dispatchEvent(new Event("input", { bubbles: true }))
    }

    // Dispatch event for flow preview update
    document.dispatchEvent(new CustomEvent("workflow:updated"))
  }

  /**
   * Sync current DOM input values to this.transitions
   * This ensures we don't lose values when re-rendering
   */
  syncFromDOM() {
    if (!this.hasTransitionsListTarget) return

    const transitionEls = this.transitionsListTarget.querySelectorAll('[data-transition-index]')
    transitionEls.forEach((el) => {
      const index = parseInt(el.dataset.transitionIndex, 10)
      if (!this.transitions[index]) return

      // Sync all field values from DOM to this.transitions
      const targetSelect = el.querySelector('[data-transition-field="target_uuid"]')
      const conditionInput = el.querySelector('[data-transition-field="condition"]')
      const labelInput = el.querySelector('[data-transition-field="label"]')

      if (targetSelect) this.transitions[index].target_uuid = targetSelect.value
      if (conditionInput) this.transitions[index].condition = conditionInput.value
      if (labelInput) this.transitions[index].label = labelInput.value
    })
  }

  /**
   * Add a new transition
   */
  addTransition(event) {
    event.preventDefault()

    // Capture current DOM values before modifying
    this.syncFromDOM()

    const newTransition = {
      target_uuid: "",
      condition: "",
      label: ""
    }

    this.transitions.push(newTransition)
    this.saveTransitions()
    this.renderTransitions()
  }

  /**
   * Remove a transition
   */
  removeTransition(event) {
    event.preventDefault()

    // Capture current DOM values before modifying
    this.syncFromDOM()

    const transitionEl = event.target.closest('[data-transition-index]')
    if (!transitionEl) return

    const index = parseInt(transitionEl.dataset.transitionIndex, 10)
    this.transitions.splice(index, 1)
    this.saveTransitions()
    this.renderTransitions()
  }

  /**
   * Update a transition field
   */
  updateTransition(event) {
    const transitionEl = event.target.closest('[data-transition-index]')
    if (!transitionEl) return

    const index = parseInt(transitionEl.dataset.transitionIndex, 10)
    const field = event.target.dataset.transitionField

    if (this.transitions[index] && field) {
      this.transitions[index][field] = event.target.value
      this.saveTransitions()
    }
  }

  renderTransitions() {
    if (!this.hasTransitionsListTarget) return

    const otherSteps = this.getOtherSteps()
    this.transitionsListTarget.replaceChildren()

    if (this.transitions.length === 0) {
      this.transitionsListTarget.appendChild(this.emptyTemplateTarget.content.cloneNode(true))
      return
    }

    this.transitions.forEach((transition, index) => {
      const row = this.rowTemplateTarget.content.firstElementChild.cloneNode(true)
      row.dataset.transitionIndex = index

      const targetSelect = row.querySelector('[data-transition-field="target_uuid"]')
      otherSteps.forEach(step => {
        const option = document.createElement("option")
        option.value = step.id
        option.textContent = step.title || `Step ${step.index + 1}`
        option.selected = step.id === transition.target_uuid
        targetSelect.appendChild(option)
      })

      // condition-preset connects when the row is inserted and reads its
      // values from these attributes, so set them before appending.
      const condition = row.querySelector('[data-controller~="condition-preset"]')
      condition.dataset.conditionPresetConditionValue = transition.condition || ""
      condition.dataset.conditionPresetLabelValue = transition.label || ""
      row.querySelector('[data-transition-field="condition"]').value = transition.condition || ""
      row.querySelector('[data-transition-field="label"]').value = transition.label || ""

      this.transitionsListTarget.appendChild(row)
    })
  }

  // Every builder row carries its own title in data-step-title; reading the
  // row's text picked up the "No connections" badge next to it.
  getOtherSteps() {
    const steps = []
    document.querySelectorAll('.builder__step[data-step-uuid]').forEach((row, index) => {
      const id = row.dataset.stepUuid
      if (id && id !== this.stepIdValue) {
        steps.push({ id, title: row.dataset.stepTitle || '', index })
      }
    })
    return steps
  }
}
