import { Controller } from "@hotwired/stimulus"
import Fuse from "fuse.js"
import { renderStepIcon } from "../services/icon_service"

export default class extends Controller {
  static targets = ["button", "dropdown", "search", "options", "hiddenInput"]
  static values = {
    selectedValue: String,
    placeholder: String,
    name: String
  }

  connect() {
    this.isOpen = false
    this.steps = []
    this.filteredSteps = []
    this.refreshDebounceTimer = null
    this.stepsLoaded = false  // Flag for lazy loading
    
    // Close dropdown when clicking outside
    this.boundHandleClickOutside = this.handleClickOutside.bind(this)
    document.addEventListener("click", this.boundHandleClickOutside)
    
    // Only render the button (not the full dropdown) on connect
    // Steps will be lazy-loaded when dropdown is first opened
    this.renderButtonOnly()
    
    // Listen for workflow changes with HEAVY debouncing - only refresh on title changes
    this.setupWorkflowChangeListener()
  }

  disconnect() {
    document.removeEventListener("click", this.boundHandleClickOutside)
    this.removeWorkflowChangeListener()
    if (this.refreshDebounceTimer) {
      clearTimeout(this.refreshDebounceTimer)
    }
  }

  setupWorkflowChangeListener() {
    const form = this.element.closest("form")
    if (!form) return
    
    // Use a targeted handler that only refreshes when step titles change
    this.workflowChangeHandler = (event) => {
      // Only react to step title changes (not every input)
      if (!event.target.matches || !event.target.matches("input[name*='[title]']")) {
        return
      }
      
      // Debounce heavily - 500ms delay to batch multiple rapid changes
      if (this.refreshDebounceTimer) {
        clearTimeout(this.refreshDebounceTimer)
      }
      
      this.refreshDebounceTimer = setTimeout(() => {
        this.loadSteps()
        this.render()
      }, 500)
    }
    
    // Only listen for input events (not change) and use capture: false
    form.addEventListener("input", this.workflowChangeHandler)
    
    // Also listen for step additions/removals via custom events (more efficient)
    this.boundRefreshHandler = this.debouncedRefresh.bind(this)
    document.addEventListener("workflow-builder:step-added", this.boundRefreshHandler)
    document.addEventListener("workflow-builder:step-removed", this.boundRefreshHandler)
    document.addEventListener("workflow-builder:steps-reordered", this.boundRefreshHandler)
  }

  removeWorkflowChangeListener() {
    const form = this.element.closest("form")
    if (form && this.workflowChangeHandler) {
      form.removeEventListener("input", this.workflowChangeHandler)
    }
    if (this.boundRefreshHandler) {
      document.removeEventListener("workflow-builder:step-added", this.boundRefreshHandler)
      document.removeEventListener("workflow-builder:step-removed", this.boundRefreshHandler)
      document.removeEventListener("workflow-builder:steps-reordered", this.boundRefreshHandler)
    }
  }
  
  debouncedRefresh() {
    if (this.refreshDebounceTimer) {
      clearTimeout(this.refreshDebounceTimer)
    }
    this.refreshDebounceTimer = setTimeout(() => {
      // Mark steps as needing reload, but don't actually load until dropdown opens
      this.stepsLoaded = false
      // If dropdown is currently open, refresh immediately
      if (this.isOpen) {
        this.loadSteps()
        this.renderOptions()
        this.stepsLoaded = true
      }
    }, 300)
  }

  handleClickOutside(event) {
    if (!this.isOpen) return
    if (!this.element.contains(event.target)) {
      this.close()
    }
  }

  loadSteps() {
    const workflowBuilder = document.querySelector("[data-controller*='workflow-builder']")
    const stepItems = workflowBuilder 
      ? workflowBuilder.querySelectorAll(".step-item")
      : document.querySelectorAll(".step-item")
    
    const currentStepItem = this.element.closest('.step-item')
    
    this.steps = []
    
    stepItems.forEach((stepItem, index) => {
      // Skip current step (can't branch to itself)
      if (stepItem === currentStepItem) return
      
      const typeInput = stepItem.querySelector("input[name*='[type]']")
      const titleInput = stepItem.querySelector("input[name*='[title]']")
      
      if (!typeInput || !titleInput) return
      
      const type = typeInput.value
      const title = titleInput.value.trim()
      
      if (!type || !title) return
      
      // Extract step details based on type
      const step = {
        index: index,
        type: type,
        title: title,
        description: "",
        preview: ""
      }
      
      // Get type-specific preview
      if (type === "question") {
        const questionInput = stepItem.querySelector("input[name*='[question]']")
        step.preview = questionInput ? questionInput.value : ""
        step.description = step.preview
      } else if (type === "action") {
        const instructionsInput = stepItem.querySelector("textarea[name*='[instructions]']")
        step.preview = instructionsInput ? instructionsInput.value.substring(0, 50) : ""
        const actionTypeInput = stepItem.querySelector("input[name*='[action_type]']")
        step.description = actionTypeInput ? actionTypeInput.value : "Action"
      } else if (type === "message") {
        step.description = "Message"
        const contentInput = stepItem.querySelector("textarea[name*='[content]']")
        step.preview = contentInput ? contentInput.value.substring(0, 50) : ""
      } else if (type === "sub_flow") {
        step.description = "Sub-Flow"
        step.preview = "Launches sub-workflow"
      }
      
      this.steps.push(step)
    })
    
    this.filteredSteps = [...this.steps]
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()
    
    if (this.isOpen) {
      this.close()
    } else {
      this.open()
    }
  }

  open() {
    if (!this.hasDropdownTarget) return
    
    this.isOpen = true
    this.dropdownTarget.classList.remove("hidden")
    this.buttonTarget.classList.add("ring-2", "ring-blue-500")
    
    // Lazy load steps when dropdown is first opened (much faster initial page load)
    if (!this.stepsLoaded) {
      this.loadSteps()
      this.renderOptions()
      this.stepsLoaded = true
    }
    
    // Focus search if available
    if (this.hasSearchTarget) {
      setTimeout(() => {
        this.searchTarget.focus()
      }, 50)
    }
  }

  close() {
    if (!this.hasDropdownTarget) return
    
    this.isOpen = false
    this.dropdownTarget.classList.add("hidden")
    this.buttonTarget.classList.remove("ring-2", "ring-blue-500")
    
    // Clear search
    if (this.hasSearchTarget) {
      this.searchTarget.value = ""
      this.filteredSteps = [...this.steps]
      this.renderOptions()
    }
  }

  search(event) {
    const query = event.target.value.trim()
    
    if (!query) {
      this.filteredSteps = [...this.steps]
    } else {
      // Use Fuse.js for fuzzy search
      const fuse = new Fuse(this.steps, {
        keys: ['title', 'preview', 'description'],
        threshold: 0.3,
        includeScore: true
      })
      
      const results = fuse.search(query)
      this.filteredSteps = results.map(result => result.item)
    }
    
    this.renderOptions()
  }

  selectStep(event) {
    event.preventDefault()
    event.stopPropagation()
    
    const stepIndex = event.currentTarget.dataset.stepIndex
    const step = this.steps.find(s => s.index.toString() === stepIndex)
    
    if (!step) return
    
    // Update hidden input
    if (this.hasHiddenInputTarget) {
      this.hiddenInputTarget.value = step.title
      this.hiddenInputTarget.dispatchEvent(new Event("change", { bubbles: true }))
    }
    
    // Update button text
    if (this.hasButtonTarget) {
      this.updateButtonText(step)
    }
    
    // Close dropdown
    this.close()
    
    // Notify parent controllers
    this.element.dispatchEvent(new CustomEvent("step-selected", {
      detail: { step: step },
      bubbles: true
    }))
  }

  updateButtonText(step) {
    if (!step) {
      const placeholder = this.hasPlaceholderValue ? this.placeholderValue : "-- Select step --"
      this.buttonTarget.innerHTML = `<span class="text-gray-500">${placeholder}</span>`
      return
    }

    const typeColor = this.getTypeColor(step.type)

    this.buttonTarget.innerHTML = `
      <div class="flex items-center gap-2">
        <span class="${typeColor}">${renderStepIcon(step.type, "w-4 h-4")}</span>
        <span class="font-medium">${this.escapeHtml(step.title)}</span>
        <span class="text-xs text-gray-500">${this.escapeHtml(step.type)}</span>
      </div>
    `
  }

  render() {
    this.renderButton()
    this.renderOptions()
  }

  // Render only the button (for lazy loading - used on connect)
  renderButtonOnly() {
    if (!this.hasButtonTarget) return
    
    // If we have a selected value, show it without loading all steps
    if (this.selectedValueValue) {
      this.buttonTarget.innerHTML = `
        <div class="flex items-center gap-2">
          <span class="font-medium">${this.escapeHtml(this.selectedValueValue)}</span>
        </div>
      `
    } else {
      const placeholder = this.hasPlaceholderValue ? this.placeholderValue : "-- Select step --"
      this.buttonTarget.innerHTML = `<span class="text-gray-500">${placeholder}</span>`
    }
  }

  renderButton() {
    if (!this.hasButtonTarget) return
    
    const selectedStep = this.steps.find(s => s.title === this.selectedValueValue)
    
    if (selectedStep) {
      this.updateButtonText(selectedStep)
    } else if (this.selectedValueValue) {
      // Show selected value even if step not found (lazy loading case)
      this.buttonTarget.innerHTML = `
        <div class="flex items-center gap-2">
          <span class="font-medium">${this.escapeHtml(this.selectedValueValue)}</span>
        </div>
      `
    } else {
      const placeholder = this.hasPlaceholderValue ? this.placeholderValue : "-- Select step --"
      this.buttonTarget.innerHTML = `<span class="text-gray-500">${placeholder}</span>`
    }
  }

  renderOptions() {
    if (!this.hasOptionsTarget) return
    
    if (this.filteredSteps.length === 0) {
      this.optionsTarget.innerHTML = `
        <div class="p-4 text-center text-gray-500 text-sm">
          No steps available
        </div>
      `
      return
    }
    
    const optionsHtml = this.filteredSteps.map(step => {
      const typeColor = this.getTypeColor(step.type)
      const isSelected = step.title === this.selectedValueValue

      return `
        <button type="button"
                class="w-full text-left p-3 hover:bg-gray-50 border-b border-gray-100 last:border-b-0 transition-colors ${isSelected ? 'bg-blue-50 border-blue-200' : ''}"
                data-action="click->step-selector#selectStep"
                data-step-index="${step.index}"
                data-step-selector-target="option">
          <div class="flex items-start gap-3">
            <div class="flex-shrink-0 mt-0.5">
              <span class="${typeColor}">${renderStepIcon(step.type, "w-5 h-5")}</span>
            </div>
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2 mb-1">
                <span class="font-medium text-gray-900">${this.escapeHtml(step.title)}</span>
                <span class="text-xs px-2 py-0.5 rounded ${this.getTypeBadgeColor(step.type)}">${this.escapeHtml(step.type)}</span>
              </div>
              ${step.preview ? `<p class="text-xs text-gray-600 truncate">${this.escapeHtml(step.preview)}</p>` : ''}
            </div>
            ${isSelected ? '<span class="text-blue-600">✓</span>' : ''}
          </div>
        </button>
      `
    }).join('')
    
    this.optionsTarget.innerHTML = optionsHtml
  }

  getTypeColor(type) {
    const colors = {
      question: "text-blue-600",
      action: "text-purple-600",
      message: "text-cyan-600",
      sub_flow: "text-indigo-600",
      escalate: "text-orange-600",
      resolve: "text-emerald-600"
    }
    return colors[type] || "text-gray-600"
  }

  getTypeBadgeColor(type) {
    const colors = {
      question: "bg-blue-100 text-blue-700",
      action: "bg-purple-100 text-purple-700",
      message: "bg-cyan-100 text-cyan-700",
      sub_flow: "bg-indigo-100 text-indigo-700",
      escalate: "bg-orange-100 text-orange-700",
      resolve: "bg-emerald-100 text-emerald-700"
    }
    return colors[type] || "bg-gray-100 text-gray-700"
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }

  // Public method to refresh steps (called by parent controllers)
  refresh() {
    this.loadSteps()
    this.render()
  }
}

