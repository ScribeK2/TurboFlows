import { Controller } from "@hotwired/stimulus"
import { renderStepIcon, renderIcon, UI_ICON_PATHS } from "services/icon_service"

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
    
    // Step type hue mapping (matches --hue-* tokens in _global.css)
    const typeHues = {
      question: 'var(--hue-question)',
      action: 'var(--hue-action)',
      sub_flow: 'var(--hue-subflow)',
      message: 'var(--hue-message)',
      escalate: 'var(--hue-escalate)',
      resolve: 'var(--hue-resolve)'
    }

    const typeIcons = {
      question: '?',
      action: '!',
      sub_flow: '\u21A9',
      message: 'i',
      escalate: '\u2191',
      resolve: '\u2713'
    }

    // Build outline items using semantic classes that match the ERB-rendered markup.
    // All values are escaped via this.escapeHtml() — no raw user input is interpolated.
    this.stepListTarget.innerHTML = steps.map((step, index) => {
      const stepHue = typeHues[step.type] || '245'
      const typeIcon = typeIcons[step.type] || '#'
      const escapedTitle = this.escapeHtml(step.title || `Untitled ${step.type || 'step'}`)
      const escapedType = this.escapeHtml(step.type || '')
      const escapedId = this.escapeHtml(step.id || '')
      return `<button type="button"
              class="step-outline-item${step.isActive ? ' is-active' : ''}"
              data-action="click->step-outline#scrollToStep"
              data-step-index="${index}"
              data-step-id="${escapedId}">
        <div class="flex items-center gap-2 overflow-hidden min-w-0">
          <span class="step-outline__number flex-shrink-0"
                style="--step-hue: ${stepHue};">${index + 1}</span>
          <span class="step-outline__type-icon flex-shrink-0"
                style="--step-hue: ${stepHue};"
                title="${escapedType}">${typeIcon}</span>
          <span class="flex-1 text-sm truncate">${escapedTitle}</span>
          ${step.hasWarning ? '<span class="flex-shrink-0" title="Incomplete" style="color: var(--color-warning);">\u26A0</span>' : ''}
        </div>
      </button>`
    }).join("")
    
    // Apply tree indentation for graph-mode workflows
    this.applyOutlineDepths()

    // Update step count
    this.updateStepCount(steps.length)
  }

  /**
   * Apply depth-based indentation to outline items for graph-mode workflows
   */
  applyOutlineDepths() {
    const startUuidInput = document.querySelector("input[name='workflow[start_node_uuid]']")
    if (!startUuidInput) return

    const startUuid = startUuidInput.value
    if (!startUuid) return

    // Build steps data from DOM for depth computation
    const stepItems = document.querySelectorAll(".step-item")
    const steps = []
    stepItems.forEach(item => {
      const idInput = item.querySelector("input[name*='[id]']")
      const transitionsInput = item.querySelector("input[name*='transitions_json']")
      let transitions = []
      if (transitionsInput?.value) {
        try { transitions = JSON.parse(transitionsInput.value) } catch (e) { /* ignore */ }
      }
      steps.push({ id: idInput?.value || '', transitions })
    })

    // Import and use buildDepthMap dynamically
    import("services/graph_utils").then(({ buildDepthMap }) => {
      const depthMap = buildDepthMap(steps, startUuid)
      const outlineItems = this.stepListTarget.querySelectorAll(".step-outline-item")

      outlineItems.forEach(item => {
        const stepId = item.dataset.stepId
        if (stepId && depthMap.has(stepId)) {
          const depth = Math.min(depthMap.get(stepId), 5)
          if (depth > 0) {
            item.style.paddingLeft = `${0.5 + depth * 1.25}rem`
            item.style.borderLeft = `2px solid var(--color-border)`
          }
        }
      })
    }).catch(() => {
      // graph_utils not available, skip indentation
    })
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
        const instructionsEditor = stepItem.querySelector(".lexxy-editor__content")
        hasWarning = !instructionsEditor?.textContent?.trim()
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
      targetStep.classList.add("is-highlighted")
      setTimeout(() => {
        targetStep.classList.remove("is-highlighted")
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
        item.classList.add("is-active")
      } else {
        item.classList.remove("is-active")
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
      this.outlineContainerTarget.classList.add("is-collapsed")
      this.outlineContainerTarget.classList.remove("is-expanded")
      this.stepListTarget?.classList.add("is-hidden")
    } else {
      this.outlineContainerTarget.classList.remove("is-collapsed")
      this.outlineContainerTarget.classList.add("is-expanded")
      this.stepListTarget?.classList.remove("is-hidden")
    }
  }

  /**
   * Show empty state
   */
  showEmptyState() {
    if (this.hasEmptyStateTarget) {
      this.emptyStateTarget.classList.remove("is-hidden")
    }
    if (this.hasStepListTarget) {
      this.stepListTarget.classList.add("is-hidden")
    }
  }

  /**
   * Hide empty state
   */
  hideEmptyState() {
    if (this.hasEmptyStateTarget) {
      this.emptyStateTarget.classList.add("is-hidden")
    }
    if (this.hasStepListTarget) {
      this.stepListTarget.classList.remove("is-hidden")
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
    // Now returns a modifier class; CSS handles the colors via step-outline-item__number--{type}
    return `step-outline-item__number--${type || 'default'}`
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

