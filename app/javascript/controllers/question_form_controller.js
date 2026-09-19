import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

export default class extends Controller {
  static targets = [
    "answerType",
    "optionsContainer",
    "optionsList",
    "emptyMarker"
  ]

  // The answer types whose options the author edits below.
  static TYPES_WITH_OPTIONS = ["multiple_choice", "dropdown"]

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

    // Unconditionally, not only from handleAnswerTypeChange above: an imported
    // Question may have no answer type checked at all, and that is exactly a
    // step whose marker must stay off.
    this.syncEmptyMarker()
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
    this.optionsChanged()
  }

  // Adding, removing or moving an option changes what the form posts without
  // anyone typing, so tell the step panel's autosave (via the options
  // container's input action) the way a keystroke would.
  optionsChanged() {
    // Before the event: that is what schedules the save which reads this form.
    this.syncEmptyMarker()
    this.optionsListTarget.dispatchEvent(new Event("input", { bubbles: true }))
  }

  // The marker is submitted ONLY when this Question takes options and has none
  // left, which is the one case an HTML form cannot say by itself.
  syncEmptyMarker() {
    if (!this.hasEmptyMarkerTarget) return

    const checked = this.answerTypeTargets.find(radio => radio.checked)
    const takesOptions = checked && this.constructor.TYPES_WITH_OPTIONS.includes(checked.value)
    const rows = this.hasOptionsListTarget ? this.optionsListTarget.querySelectorAll(".option-item").length : 0

    this.emptyMarkerTarget.disabled = !(takesOptions && rows === 0)
  }

  handleAnswerTypeChange(event, isInitial = false) {
    const answerType = event.target.value
    const typesWithOptions = this.constructor.TYPES_WITH_OPTIONS

    // Switching away from a type with options throws the options away, so ask.
    // A refused change puts the previous radio back and stops the autosave
    // action queued after this one on the same radio: nothing is written.
    if (!isInitial &&
        typesWithOptions.includes(this.previousAnswerType) &&
        !typesWithOptions.includes(answerType) &&
        this.hasExistingOptions()) {
      if (!confirm('Changing answer type will remove existing options. Continue?')) {
        event.target.checked = false
        const previousRadio = this.answerTypeTargets.find(radio => radio.value === this.previousAnswerType)
        if (previousRadio) previousRadio.checked = true
        event.stopImmediatePropagation()
        return
      }
    }

    this.previousAnswerType = answerType
    this.syncEmptyMarker()

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
               name="step[options][][label]"
               placeholder="Option label"
               class="form-input flex-1">
        <input type="text"
               name="step[options][][value]"
               placeholder="Option value"
               class="form-input flex-1">
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
    this.optionsChanged()
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
      this.optionsChanged()
    }
  }
}

