import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

export default class extends Controller {
  static targets = [
    "answerType",
    "hiddenAnswerType",
    "optionsContainer",
    "optionsList"
  ]

  connect() {
    // Set initial state based on checked radio button
    const checked = this.answerTypeTargets.find(radio => radio.checked)
    if (checked) {
      this.previousAnswerType = checked.value
      this.handleAnswerTypeChange({ target: checked }, true)
    }

    // Initialize Sortable for options list if visible
    if (this.hasOptionsListTarget && !this.optionsListTarget.classList.contains('is-hidden')) {
      this.initializeSortable()
    }
  }

  disconnect() {
    if (this.sortable) {
      this.sortable.destroy()
    }
  }

  initializeSortable() {
    if (!this.hasOptionsListTarget) return
    
    try {
      this.sortable = new Sortable(this.optionsListTarget, {
        handle: '.drag-handle',
        animation: 150,
        ghostClass: 'is-dragging',
        onEnd: () => this.handleReorder()
      })
    } catch (error) {
      console.error("Failed to load Sortable:", error)
    }
  }

  handleReorder() {
    // Trigger input event to update preview
    this.element.dispatchEvent(new CustomEvent('input', { bubbles: true }))
  }

  handleAnswerTypeChange(event, isInitial = false) {
    const answerType = event.target.value
    const typesWithOptions = ['multiple_choice', 'dropdown']

    // Check if switching away from a type with options and options exist
    if (!isInitial &&
        typesWithOptions.includes(this.previousAnswerType) &&
        !typesWithOptions.includes(answerType) &&
        this.hasExistingOptions()) {
      if (!confirm('Changing answer type will remove existing options. Continue?')) {
        // Revert to previous answer type
        event.target.checked = false
        const previousRadio = this.answerTypeTargets.find(
          radio => radio.value === this.previousAnswerType
        )
        if (previousRadio) {
          previousRadio.checked = true
        }
        return
      }
    }

    // Update previous answer type for next comparison
    this.previousAnswerType = answerType

    // Update hidden input
    if (this.hasHiddenAnswerTypeTarget) {
      this.hiddenAnswerTypeTarget.value = answerType
    }

    // Update visual highlight on radio labels
    this.answerTypeTargets.forEach(radio => {
      const label = radio.closest('label')
      if (!label) return
      if (radio.value === answerType) {
        label.classList.add('is-selected')
      } else {
        label.classList.remove('is-selected')
      }
    })

    // Show/hide options container based on answer type
    if (this.hasOptionsContainerTarget) {
      if (typesWithOptions.includes(answerType)) {
        this.optionsContainerTarget.classList.remove('is-hidden')
        // Initialize Sortable if not already initialized
        if (!this.sortable && this.hasOptionsListTarget) {
          setTimeout(() => this.initializeSortable(), 100)
        }
      } else {
        this.optionsContainerTarget.classList.add('is-hidden')
        // Destroy Sortable when hidden
        if (this.sortable) {
          this.sortable.destroy()
          this.sortable = null
        }
      }
    }

    // Dispatch event for preview updater
    this.element.dispatchEvent(new CustomEvent('answer-type-changed', {
      detail: { answerType },
      bubbles: true
    }))
  }

  hasExistingOptions() {
    if (!this.hasOptionsListTarget) return false
    const optionItems = this.optionsListTarget.querySelectorAll('.option-item')
    if (optionItems.length === 0) return false

    // Check if at least one option has a value
    for (const item of optionItems) {
      const inputs = item.querySelectorAll('input[type="text"]')
      for (const input of inputs) {
        if (input.value.trim()) {
          return true
        }
      }
    }
    return false
  }

  addOption(event) {
    event.preventDefault()
    event.stopPropagation()
    
    if (!this.hasOptionsListTarget) return
    
    const optionHtml = `
      <div class="option-item">
        <span class="drag-handle" title="Drag to reorder">☰</span>
        <input type="text"
               name="workflow[steps][][options][][label]"
               placeholder="Option label"
               class="form-input flex-1"
               data-step-form-target="field">
        <input type="text"
               name="workflow[steps][][options][][value]"
               placeholder="Option value"
               class="form-input flex-1"
               data-step-form-target="field">
        <button type="button"
                class="btn btn--plain btn--sm option-item__delete"
                data-action="click->question-form#removeOption"
                title="Remove option">
          <svg class="icon icon--sm" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
          </svg>
        </button>
      </div>
    `
    
    this.optionsListTarget.insertAdjacentHTML('beforeend', optionHtml)
    
    // Reinitialize Sortable after adding new element
    if (this.sortable) {
      this.sortable.destroy()
    }
    this.initializeSortable()
  }

  removeOption(event) {
    event.preventDefault()
    event.stopPropagation()
    
    const optionDiv = event.target.closest('.option-item')
    if (optionDiv) {
      optionDiv.remove()
      
      // Reinitialize Sortable after removing element
      if (this.sortable) {
        this.sortable.destroy()
      }
      this.initializeSortable()
    }
  }
}

