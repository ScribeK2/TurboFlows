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
    if (this.hasOptionsListTarget && !this.optionsListTarget.classList.contains('hidden')) {
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
        ghostClass: 'opacity-50',
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
        this.optionsContainerTarget.classList.remove('hidden')
        // Initialize Sortable if not already initialized
        if (!this.sortable && this.hasOptionsListTarget) {
          setTimeout(() => this.initializeSortable(), 100)
        }
      } else {
        this.optionsContainerTarget.classList.add('hidden')
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
      <div class="flex gap-2 items-center option-item">
        <span class="drag-handle cursor-move text-gray-500 text-lg flex-shrink-0" title="Drag to reorder">☰</span>
        <input type="text" 
               name="workflow[steps][][options][][label]" 
               placeholder="Option label" 
               class="flex-1 border rounded px-2 py-1 text-sm min-w-0"
               data-step-form-target="field">
        <input type="text" 
               name="workflow[steps][][options][][value]" 
               placeholder="Option value" 
               class="flex-1 border rounded px-2 py-1 text-sm min-w-0"
               data-step-form-target="field">
        <button type="button" 
                class="text-red-500 hover:text-red-700 text-sm px-2 flex-shrink-0"
                data-action="click->question-form#removeOption">
          Remove
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

