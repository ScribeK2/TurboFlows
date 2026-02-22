import { Controller } from "@hotwired/stimulus"
import { renderStepIcon, renderIcon, UI_ICON_PATHS } from "../services/icon_service"

/**
 * Step Outline Controller
 *
 * Sprint 3: Navigation & Visual Improvements
 * Provides a sidebar navigation outline for long workflows.
 * Shows all steps with quick navigation and status indicators.
 */
export default class extends Controller {
  static targets = [
    "outlineContainer",
    "stepList",
    "currentStepIndicator",
    "toggleButton",
    "emptyState"
  ]

  static values = {
    collapsed: { type: Boolean, default: false }
  }

  connect() {
    // Initial render of the outline
    this.renderOutline()
    
    // Listen for workflow changes
    this.setupChangeListener()
    
    // Observe scroll position to highlight current step
    this.setupScrollObserver()
  }

  disconnect() {
    this.removeChangeListener()
    this.removeScrollObserver()
  }

  /**
   * Render the step outline from the current form state
   */
  renderOutline() {
    if (!this.hasStepListTarget) return
    
    const steps = this.getStepsFromForm()
    
    if (steps.length === 0) {
      this.showEmptyState()
      return
    }
    
    this.hideEmptyState()
    
    // Render step list
    this.stepListTarget.innerHTML = steps.map((step, index) => `
      <button type="button"
              class="step-outline-item w-full text-left px-3 py-2 rounded-lg transition-all duration-200 group
                     hover:bg-gray-100 dark:hover:bg-gray-700/50
                     ${step.isActive ? 'bg-blue-50 dark:bg-blue-900/30 border-l-2 border-blue-500' : ''}"
              data-action="click->step-outline#scrollToStep"
              data-step-index="${index}"
              data-step-id="${step.id}">
        <div class="flex items-center gap-2">
          <span class="flex-shrink-0 w-6 h-6 rounded-full text-xs font-medium flex items-center justify-center
                       ${this.getStepNumberClasses(step.type)}">
            ${index + 1}
          </span>
          <span class="flex-shrink-0" title="${step.type}">
            ${renderStepIcon(step.type, "w-4 h-4")}
          </span>
          <span class="flex-1 text-sm truncate text-gray-700 dark:text-gray-300 group-hover:text-gray-900 dark:group-hover:text-gray-100">
            ${this.escapeHtml(step.title || `Untitled ${step.type || 'step'}`)}
          </span>
          ${step.hasWarning ? `<span class="flex-shrink-0 text-amber-500" title="Incomplete">${renderIcon(UI_ICON_PATHS.warning, "w-4 h-4")}</span>` : ''}
        </div>
      </button>
    `).join("")
    
    // Update step count
    this.updateStepCount(steps.length)
  }

  /**
   * Get steps data from the form
   */
  getStepsFromForm() {
    const steps = []
    const stepItems = document.querySelectorAll(".step-item")
    
    stepItems.forEach((stepItem, index) => {
      const typeInput = stepItem.querySelector("input[name*='[type]']")
      const titleInput = stepItem.querySelector("input[name*='[title]']")
      const idInput = stepItem.querySelector("input[name*='[id]']")
      
      const type = typeInput?.value || ''
      const title = titleInput?.value || ''
      const id = idInput?.value || `step-${index}`
      
      // Check for incomplete steps
      let hasWarning = false
      if (type === 'question') {
        const questionInput = stepItem.querySelector("textarea[name*='[question]'], input[name*='[question]']")
        hasWarning = !questionInput?.value?.trim()
      } else if (type === 'action') {
        const instructionsInput = stepItem.querySelector("textarea[name*='[instructions]']")
        hasWarning = !instructionsInput?.value?.trim()
      }
      
      steps.push({
        index,
        id,
        type,
        title,
        hasWarning,
        isActive: false
      })
    })
    
    return steps
  }

  /**
   * Scroll to a specific step
   */
  scrollToStep(event) {
    const stepIndex = event.currentTarget.dataset.stepIndex
    const stepItems = document.querySelectorAll(".step-item")
    const targetStep = stepItems[stepIndex]
    
    if (targetStep) {
      // Scroll into view with offset for fixed header
      const headerOffset = 100
      const elementPosition = targetStep.getBoundingClientRect().top
      const offsetPosition = elementPosition + window.pageYOffset - headerOffset
      
      window.scrollTo({
        top: offsetPosition,
        behavior: "smooth"
      })
      
      // Expand the step if collapsed
      const collapsibleController = window.Stimulus?.getControllerForElementAndIdentifier(
        targetStep.querySelector("[data-controller*='collapsible-step']"),
        "collapsible-step"
      )
      if (collapsibleController) {
        collapsibleController.expand()
      }
      
      // Highlight the step briefly
      targetStep.classList.add("ring-2", "ring-blue-500", "ring-offset-2")
      setTimeout(() => {
        targetStep.classList.remove("ring-2", "ring-blue-500", "ring-offset-2")
      }, 1500)
      
      // Update active state in outline
      this.setActiveStep(stepIndex)
    }
  }

  /**
   * Set the active step in the outline
   */
  setActiveStep(index) {
    const items = this.stepListTarget?.querySelectorAll(".step-outline-item")
    items?.forEach((item, i) => {
      if (i == index) {
        item.classList.add("bg-blue-50", "dark:bg-blue-900/30", "border-l-2", "border-blue-500")
      } else {
        item.classList.remove("bg-blue-50", "dark:bg-blue-900/30", "border-l-2", "border-blue-500")
      }
    })
  }

  /**
   * Toggle sidebar collapsed state
   */
  toggle() {
    this.collapsedValue = !this.collapsedValue
    this.updateCollapsedState()
  }

  /**
   * Update UI based on collapsed state
   */
  updateCollapsedState() {
    if (!this.hasOutlineContainerTarget) return
    
    if (this.collapsedValue) {
      this.outlineContainerTarget.classList.add("w-12")
      this.outlineContainerTarget.classList.remove("w-64")
      this.stepListTarget?.classList.add("hidden")
    } else {
      this.outlineContainerTarget.classList.remove("w-12")
      this.outlineContainerTarget.classList.add("w-64")
      this.stepListTarget?.classList.remove("hidden")
    }
  }

  /**
   * Show empty state
   */
  showEmptyState() {
    if (this.hasEmptyStateTarget) {
      this.emptyStateTarget.classList.remove("hidden")
    }
    if (this.hasStepListTarget) {
      this.stepListTarget.classList.add("hidden")
    }
  }

  /**
   * Hide empty state
   */
  hideEmptyState() {
    if (this.hasEmptyStateTarget) {
      this.emptyStateTarget.classList.add("hidden")
    }
    if (this.hasStepListTarget) {
      this.stepListTarget.classList.remove("hidden")
    }
  }

  /**
   * Update step count display
   */
  updateStepCount(count) {
    const countElement = this.element.querySelector("[data-step-count]")
    if (countElement) {
      countElement.textContent = `${count} step${count !== 1 ? 's' : ''}`
    }
  }

  /**
   * Get CSS classes for step number badge based on type
   */
  getStepNumberClasses(type) {
    const classes = {
      question: "bg-blue-100 text-blue-700 dark:bg-blue-900/50 dark:text-blue-300",
      action: "bg-green-100 text-green-700 dark:bg-green-900/50 dark:text-green-300",
      sub_flow: "bg-indigo-100 text-indigo-700 dark:bg-indigo-900/50 dark:text-indigo-300",
      message: "bg-cyan-100 text-cyan-700 dark:bg-cyan-900/50 dark:text-cyan-300",
      escalate: "bg-orange-100 text-orange-700 dark:bg-orange-900/50 dark:text-orange-300",
      resolve: "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/50 dark:text-emerald-300"
    }
    return classes[type] || "bg-gray-100 text-gray-700 dark:bg-gray-700 dark:text-gray-300"
  }

  /**
   * Setup listener for workflow changes
   */
  setupChangeListener() {
    const form = document.querySelector("form")
    if (!form) return
    
    this.changeHandler = () => {
      // Debounce updates
      clearTimeout(this.updateTimeout)
      this.updateTimeout = setTimeout(() => {
        this.renderOutline()
      }, 300)
    }
    
    form.addEventListener("input", this.changeHandler)
    form.addEventListener("change", this.changeHandler)
    
    // Also listen for step additions/removals
    document.addEventListener("workflow:updated", this.changeHandler)
    document.addEventListener("workflow-steps-changed", this.changeHandler)
  }

  /**
   * Remove change listener
   */
  removeChangeListener() {
    const form = document.querySelector("form")
    if (form && this.changeHandler) {
      form.removeEventListener("input", this.changeHandler)
      form.removeEventListener("change", this.changeHandler)
    }
    document.removeEventListener("workflow:updated", this.changeHandler)
    document.removeEventListener("workflow-steps-changed", this.changeHandler)
  }

  /**
   * Setup scroll observer to track current step
   */
  setupScrollObserver() {
    if (!("IntersectionObserver" in window)) return
    
    this.scrollObserver = new IntersectionObserver(
      (entries) => {
        entries.forEach(entry => {
          if (entry.isIntersecting) {
            const stepIndex = entry.target.dataset.stepIndex
            if (stepIndex !== undefined) {
              this.setActiveStep(stepIndex)
            }
          }
        })
      },
      {
        root: null,
        rootMargin: "-100px 0px -60% 0px",
        threshold: 0
      }
    )
    
    // Observe all step items
    document.querySelectorAll(".step-item").forEach(item => {
      this.scrollObserver.observe(item)
    })
  }

  /**
   * Remove scroll observer
   */
  removeScrollObserver() {
    if (this.scrollObserver) {
      this.scrollObserver.disconnect()
    }
  }

  /**
   * Escape HTML to prevent XSS
   */
  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}

