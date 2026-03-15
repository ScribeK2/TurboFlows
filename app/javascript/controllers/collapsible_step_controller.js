import { Controller } from "@hotwired/stimulus"

/**
 * Collapsible Step Controller
 * 
 * Sprint 2: Action Step Simplification
 * Provides collapsible step cards for better organization of long workflows.
 * Steps can be expanded/collapsed individually or all at once.
 */
export default class extends Controller {
  static targets = [
    "header",
    "content",
    "toggleIcon",
    "stepSummary",
    "expandAllButton"
  ]

  static values = {
    expanded: { type: Boolean, default: true },
    stepType: String,
    stepTitle: String
  }

  connect() {
    // Set initial state based on expanded value
    this.updateVisibility()
    
    // Generate summary for collapsed state
    this.updateSummary()
    
    // Listen for step form changes to update summary
    this.setupChangeListener()
  }

  disconnect() {
    this.removeChangeListener()
  }

  /**
   * Toggle expanded/collapsed state
   */
  toggle() {
    this.expandedValue = !this.expandedValue
    this.updateVisibility()
  }

  /**
   * Expand the step
   */
  expand() {
    this.expandedValue = true
    this.updateVisibility()
  }

  /**
   * Collapse the step
   */
  collapse() {
    this.expandedValue = false
    this.updateVisibility()
  }

  /**
   * Update visibility based on expanded state
   */
  updateVisibility() {
    if (this.hasContentTarget) {
      if (this.expandedValue) {
        this.contentTarget.classList.remove("is-hidden")
        this.contentTarget.style.maxHeight = ""
      } else {
        this.contentTarget.classList.add("is-hidden")
      }
    }
    
    // Update toggle icon rotation
    if (this.hasToggleIconTarget) {
      this.toggleIconTarget.style.transform = this.expandedValue ? "rotate(180deg)" : "rotate(0deg)"
    }
    
    // Show/hide summary
    if (this.hasStepSummaryTarget) {
      if (this.expandedValue) {
        this.stepSummaryTarget.classList.add("is-hidden")
      } else {
        this.stepSummaryTarget.classList.remove("is-hidden")
        this.updateSummary()
      }
    }
    
    // Update header styles
    if (this.hasHeaderTarget) {
      this.headerTarget.classList.toggle("rounded-b-lg", !this.expandedValue)
    }
  }

  /**
   * Generate a summary for the collapsed state
   */
  updateSummary() {
    if (!this.hasStepSummaryTarget) return
    
    const stepItem = this.element.closest(".step-item")
    if (!stepItem) return
    
    // Get step type
    const typeInput = stepItem.querySelector("input[name*='[type]']")
    const stepType = typeInput?.value || this.stepTypeValue
    
    // Get relevant content based on step type
    let summary = ""
    
    switch (stepType) {
      case "question":
        const questionInput = stepItem.querySelector("textarea[name*='[question]'], input[name*='[question]']")
        const answerType = stepItem.querySelector("input[name*='[answer_type]']:checked, input[name*='[answer_type]'][type='hidden']")
        summary = this.truncate(questionInput?.value || "No question set", 60)
        if (answerType?.value) {
          summary += ` (${this.formatAnswerType(answerType.value)})`
        }
        break
        
      case "action":
        const instructions = stepItem.querySelector("textarea[name*='[instructions]']")
        summary = this.truncate(instructions?.value || "No instructions set", 60)
        break

      case "message":
        const messageContent = stepItem.querySelector("textarea[name*='[content]']")
        summary = this.truncate(messageContent?.value || "No content set", 60)
        break
        
      default:
        summary = "Configure this step"
    }
    
    this.stepSummaryTarget.textContent = summary
  }

  /**
   * Format answer type for display
   */
  formatAnswerType(type) {
    const types = {
      yes_no: "Yes/No",
      multiple_choice: "Multiple Choice",
      text: "Text",
      number: "Number",
      dropdown: "Dropdown"
    }
    return types[type] || type
  }

  /**
   * Truncate text to specified length
   */
  truncate(text, maxLength) {
    if (!text) return ""
    text = text.trim()
    if (text.length <= maxLength) return text
    return text.substring(0, maxLength).trim() + "..."
  }

  /**
   * Setup listener for form changes
   */
  setupChangeListener() {
    const stepItem = this.element.closest(".step-item")
    if (!stepItem) return
    
    this.changeHandler = () => {
      this.updateSummary()
    }
    
    stepItem.addEventListener("input", this.changeHandler)
    stepItem.addEventListener("change", this.changeHandler)
  }

  /**
   * Remove change listener
   */
  removeChangeListener() {
    const stepItem = this.element.closest(".step-item")
    if (stepItem && this.changeHandler) {
      stepItem.removeEventListener("input", this.changeHandler)
      stepItem.removeEventListener("change", this.changeHandler)
    }
  }

  // ============================================================================
  // Static methods for global expand/collapse (called from workflow builder)
  // ============================================================================

  /**
   * Expand all steps in a container
   */
  static expandAll(container) {
    const controllers = container.querySelectorAll("[data-controller*='collapsible-step']")
    controllers.forEach(element => {
      const controller = window.Stimulus?.getControllerForElementAndIdentifier(element, "collapsible-step")
      if (controller) {
        controller.expand()
      }
    })
  }

  /**
   * Collapse all steps in a container
   */
  static collapseAll(container) {
    const controllers = container.querySelectorAll("[data-controller*='collapsible-step']")
    controllers.forEach(element => {
      const controller = window.Stimulus?.getControllerForElementAndIdentifier(element, "collapsible-step")
      if (controller) {
        controller.collapse()
      }
    })
  }
}

