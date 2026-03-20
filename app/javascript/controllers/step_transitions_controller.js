import { Controller } from "@hotwired/stimulus"

/**
 * Step Transitions Controller
 *
 * Manages the connections/transitions UI for graph mode workflows.
 * Each step can have multiple transitions to other steps, with optional conditions.
 */
export default class extends Controller {
  static targets = ["transitionsList", "hiddenInput"]
  static values = {
    stepId: String,
    stepIndex: Number
  }

  connect() {
    console.log(`[StepTransitions] Connected for step ${this.stepIdValue}`)
    this.refresh()

    // Debug: log hidden input state
    const hiddenInput = this.element.closest('.step-item')?.querySelector('input[name*="transitions_json"]')
    console.log(`[StepTransitions] Hidden input found: ${!!hiddenInput}`, hiddenInput?.value?.substring(0, 100))
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
    const hiddenInput = this.element.closest('.step-item')?.querySelector('input[name*="transitions_json"]')
    if (hiddenInput && hiddenInput.value) {
      try {
        return JSON.parse(hiddenInput.value)
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
    const hiddenInput = this.element.closest('.step-item')?.querySelector('input[name*="transitions_json"]')
    if (hiddenInput) {
      const jsonValue = JSON.stringify(this.transitions)
      hiddenInput.value = jsonValue
      console.log(`[StepTransitions] Saved to hidden input for step ${this.stepIdValue}:`, jsonValue)
    } else {
      console.error(`[StepTransitions] Hidden input NOT FOUND for step ${this.stepIdValue}`)
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

  /**
   * Render the transitions list
   */
  renderTransitions() {
    if (!this.hasTransitionsListTarget) return

    // Get other steps from the workflow
    const otherSteps = this.getOtherSteps()

    if (this.transitions.length === 0) {
      this.transitionsListTarget.innerHTML = `
        <p class="transitions-empty">
          No connections yet. Add a connection to link this step to another.
        </p>
      `
      return
    }

    const html = this.transitions.map((transition, index) => {
      const optionsHtml = otherSteps.map(step => {
        const selected = transition.target_uuid === step.id ? 'selected' : ''
        const title = step.title || `Step ${step.index + 1}`
        return `<option value="${this.escapeHtml(step.id)}" ${selected}>${this.escapeHtml(title)}</option>`
      }).join('')

      return `
        <div class="transition-item"
             data-transition-index="${index}">
          <svg class="transition-item__arrow" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 7l5 5m0 0l-5 5m5-5H6"/>
          </svg>
          <select data-action="change->step-transitions#updateTransition"
                  data-transition-field="target_uuid"
                  class="form-select transition-item__target">
            <option value="">-- Select target step --</option>
            ${optionsHtml}
          </select>
          <div class="transition-item__condition"
               data-controller="condition-preset"
               data-condition-preset-condition-value="${this.escapeHtml(transition.condition || '')}"
               data-condition-preset-label-value="${this.escapeHtml(transition.label || '')}">
            <select data-condition-preset-target="presetDropdown"
                    data-action="change->condition-preset#handlePresetChange"
                    class="form-select"
                    title="Select a condition preset or choose Custom">
            </select>
            <div data-condition-preset-target="numericContainer" class="is-hidden condition-preset__numeric">
              <input type="number"
                     data-condition-preset-target="numericValueInput"
                     data-action="input->condition-preset#handleNumericChange"
                     placeholder="Value"
                     class="form-input form-input--sm">
            </div>
            <div data-condition-preset-target="customContainer" class="is-hidden condition-preset__custom">
              <input type="text"
                     data-condition-preset-target="customInput"
                     data-action="input->condition-preset#handleCustomInput"
                     placeholder='e.g., answer == "yes"'
                     class="form-input">
            </div>
            <input type="hidden"
                   data-condition-preset-target="conditionHidden"
                   data-transition-field="condition"
                   data-action="input->step-transitions#updateTransition"
                   value="${this.escapeHtml(transition.condition || '')}">
          </div>
          <input type="text"
                 data-action="input->step-transitions#updateTransition input->condition-preset#handleLabelInput"
                 data-transition-field="label"
                 data-condition-preset-target="labelInput"
                 value="${this.escapeHtml(transition.label || '')}"
                 placeholder="Label"
                 title="Display label for this connection"
                 class="form-input transition-item__label">
          <button type="button"
                  data-action="click->step-transitions#removeTransition"
                  class="btn btn--negative btn--sm"
                  title="Remove connection">
            <svg class="icon icon--sm" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
            </svg>
          </button>
        </div>
      `
    }).join('')

    this.transitionsListTarget.innerHTML = html
  }

  /**
   * Get other steps in the workflow (excluding current step)
   */
  getOtherSteps() {
    const steps = []
    const stepItems = document.querySelectorAll('.step-item')

    stepItems.forEach((item, index) => {
      // Support both old (name*="[id]") and new (data-step-field="id") markup
      const idInput = item.querySelector('input[data-step-field="id"]') || item.querySelector('input[name*="[id]"]')
      const titleInput = item.querySelector('input[data-step-field="title"]') || item.querySelector('input[name*="[title]"]')

      if (idInput && idInput.value !== this.stepIdValue) {
        steps.push({
          id: idInput.value,
          title: titleInput?.value || '',
          index: index
        })
      }
    })

    return steps
  }

  /**
   * Escape HTML to prevent XSS
   * Note: textContent->innerHTML only escapes <, >, &
   * We also need to escape quotes for use in HTML attributes
   */
  escapeHtml(text) {
    if (!text) return ''
    const div = document.createElement('div')
    div.textContent = text
    // innerHTML escapes <, >, & but NOT quotes
    // Escape quotes for safe use in HTML attribute values
    return div.innerHTML.replace(/"/g, '&quot;').replace(/'/g, '&#39;')
  }
}
