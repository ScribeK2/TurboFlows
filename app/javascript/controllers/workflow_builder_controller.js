import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"
import {
  buildStepHtml,
  getWorkflowIdFromForm,
  escapeHtml
} from "controllers/workflow_builder_step_templates"

export default class extends Controller {
  static targets = ["container"]
  static values = {
    workflowId: Number,
    debug: { type: Boolean, default: false }
  }

  static STEP_DEFAULTS = {
    question:   { question: "", answer_type: "yes_no", variable_name: "" },
    action:     { action_type: "Instruction", instructions: "" },
    sub_flow:   { target_workflow_id: "", variable_mapping: {} },
    message:    { content: "" },
    escalate:   { target_type: "", target_value: "", priority: "normal", reason_required: false, notes: "" },
    resolve:    { resolution_type: "success", resolution_code: "", notes_required: false, survey_trigger: false }
  }

  connect() {
    this.initializeSortable()
    // Listen for step addition from modal (kept for backward compatibility)
    this.boundHandleModalAddStep = this.handleModalAddStep.bind(this)
    document.addEventListener("step-modal:add-step", this.boundHandleModalAddStep)
    // Listen for inline step creation (Sprint 3)
    this.boundHandleInlineStepCreate = this.handleInlineStepCreate.bind(this)
    document.addEventListener("inline-step:create", this.boundHandleInlineStepCreate)
    // Set up event listeners for title changes (debounced)
    this.setupTitleChangeListeners()
    
    // Skip initial dropdown refresh - step_selector controllers handle their own initialization
    // This prevents O(n²) DOM queries on page load for large workflows
    // Dropdowns will be populated lazily when opened
  }

  disconnect() {
    if (this.sortable) {
      this.sortable.destroy()
    }
    if (this.boundHandleModalAddStep) {
      document.removeEventListener("step-modal:add-step", this.boundHandleModalAddStep)
    }
    if (this.boundHandleInlineStepCreate) {
      document.removeEventListener("inline-step:create", this.boundHandleInlineStepCreate)
    }
    // Clean up container listeners
    if (this.hasContainerTarget) {
      if (this.boundContainerInputHandler) {
        this.containerTarget.removeEventListener("input", this.boundContainerInputHandler)
      }
      if (this.boundContainerChangeHandler) {
        this.containerTarget.removeEventListener("change", this.boundContainerChangeHandler)
      }
    }
    // Clear debounce timers
    if (this.titleChangeDebounceTimer) {
      clearTimeout(this.titleChangeDebounceTimer)
    }
    if (this.variableChangeDebounceTimer) {
      clearTimeout(this.variableChangeDebounceTimer)
    }
  }
  
  /**
   * Handle inline step creation (Sprint 3)
   */
  async handleInlineStepCreate(event) {
    const { type, afterIndex } = event.detail
    this.log(`[WorkflowBuilder] Creating inline step of type ${type} after index ${afterIndex}`)
    
    // Create the step with default data
    const stepData = {
      title: "",
      description: "",
      ...(this.constructor.STEP_DEFAULTS[type] || {})
    }

    // Insert the step at the specified position
    await this.addStepFromModal(type, stepData, afterIndex + 1)
  }

  async handleModalAddStep(event) {
    const { stepType, stepData } = event.detail
    this.log(`[WorkflowBuilder] Adding step from modal: ${stepType}`, stepData)
    await this.addStepFromModal(stepType, stepData)
  }

  /**
   * Add a step directly without opening the modal (Sprint 3.5)
   * This provides a more streamlined UX where clicking "Add Question" 
   * immediately adds a step that's ready for editing.
   */
  async addStepDirect(event) {
    event.preventDefault()
    
    const stepType = event.currentTarget.dataset.stepType
    if (!stepType) {
      console.error("[WorkflowBuilder] No step type specified")
      return
    }
    
    this.log(`[WorkflowBuilder] Adding step directly: ${stepType}`)
    
    // Create default step data based on type
    const stepData = {
      title: "",
      description: "",
      ...(this.constructor.STEP_DEFAULTS[stepType] || {})
    }

    // Add the step at the end
    await this.addStepFromModal(stepType, stepData)
  }

  initializeSortable() {
    if (!this.hasContainerTarget) {
      return
    }
    
    try {
      this.sortable = Sortable.create(this.containerTarget, {
        animation: 150,
        handle: ".drag-handle",
        onEnd: (event) => {
          this.updateOrder(event)
          this.refreshAllDropdowns()
          
          // Dispatch event for collaboration
          const newOrder = Array.from(this.containerTarget.querySelectorAll(".step-item")).map((step, index) => {
            const indexInput = step.querySelector("input[name*='[index]']")
            return indexInput ? parseInt(indexInput.value) : index
          })
          document.dispatchEvent(new CustomEvent("workflow-builder:steps-reordered", {
            detail: { newOrder }
          }))
        }
      })
    } catch (error) {
      console.error("Failed to load Sortable:", error)
    }
  }

  setupTitleChangeListeners() {
    if (!this.hasContainerTarget) return

    // Debounce timers for expensive operations
    this.titleChangeDebounceTimer = null
    this.variableChangeDebounceTimer = null

    // Use event delegation to handle title changes with debouncing
    // Store bound handler for cleanup
    this.boundContainerInputHandler = (event) => {
      if (event.target.matches("input[name*='[title]']")) {
        // Debounce dropdown refresh - 500ms delay to batch rapid typing
        if (this.titleChangeDebounceTimer) {
          clearTimeout(this.titleChangeDebounceTimer)
        }
        this.titleChangeDebounceTimer = setTimeout(() => {
          // Note: step_selector controllers now handle their own refresh
          // We only need to notify the preview
          this.notifyPreviewUpdate()
        }, 500)
      }
      // Also refresh variable dropdowns when variable names change (debounced)
      if (event.target.matches("input[name*='[variable_name]']")) {
        if (this.variableChangeDebounceTimer) {
          clearTimeout(this.variableChangeDebounceTimer)
        }
        this.variableChangeDebounceTimer = setTimeout(() => {
          this.refreshAllRuleBuilders()
        }, 500)
      }
    }
    this.containerTarget.addEventListener("input", this.boundContainerInputHandler)

    // Also listen for select changes (dropdown updates)
    // Store bound handler for cleanup
    this.boundContainerChangeHandler = (event) => {
      if (event.target.matches("select[name*='[true_path]'], select[name*='[false_path]']")) {
        this.notifyPreviewUpdate()
      }
    }
    this.containerTarget.addEventListener("change", this.boundContainerChangeHandler)
  }

  refreshAllRuleBuilders() {
    // Notify all rule builder controllers to refresh their variable dropdowns
    const form = this.element.closest("form")
    if (!form) return
    
    const ruleBuilders = form.querySelectorAll("[data-controller*='rule-builder']")
    ruleBuilders.forEach(element => {
      const application = window.Stimulus
      if (application) {
        const controller = application.getControllerForElementAndIdentifier(element, "rule-builder")
        if (controller && typeof controller.refreshVariables === 'function') {
          controller.refreshVariables()
        }
      }
    })
  }

  notifyPreviewUpdate() {
    // Dispatch custom event for flow preview to listen to
    document.dispatchEvent(new CustomEvent("workflow:updated"))
  }

  /**
   * Handle graph mode toggle
   */
  toggleGraphMode(event) {
    const enabled = event.target.checked
    this.log(`[WorkflowBuilder] Graph mode ${enabled ? 'enabled' : 'disabled'}`)

    // Notify the preview to update
    this.notifyPreviewUpdate()

    // Show/hide sub-flow button based on graph mode
    const subflowButton = document.querySelector('[data-step-type="sub_flow"]')
    if (subflowButton) {
      subflowButton.style.display = enabled ? '' : 'none'
    }

    // Dispatch event for other components
    document.dispatchEvent(new CustomEvent("workflow:graph-mode-changed", {
      detail: { enabled }
    }))
  }

  // Get all step titles from the current form
  getAllStepTitles(excludeIndex = null) {
    const titles = []
    const stepItems = this.containerTarget.querySelectorAll(".step-item")
    
    stepItems.forEach((stepItem, index) => {
      if (excludeIndex !== null && index === excludeIndex) return
      
      const titleInput = stepItem.querySelector("input[name*='[title]']")
      if (titleInput && titleInput.value.trim()) {
        titles.push({
          value: titleInput.value.trim(),
          index: index
        })
      }
    })
    
    return titles
  }

  // Generate dropdown options HTML
  buildDropdownOptions(stepTitles, currentValue = "") {
    let options = '<option value="">-- Select step --</option>'
    let currentValueFound = false
    
    stepTitles.forEach(title => {
      const selected = title.value === currentValue ? "selected" : ""
      if (selected) currentValueFound = true
      options += `<option value="${escapeHtml(title.value)}" ${selected}>${escapeHtml(title.value)}</option>`
    })

    // If currentValue exists but isn't in the list, preserve it (broken reference)
    if (currentValue && !currentValueFound) {
      options += `<option value="${escapeHtml(currentValue)}" selected>${escapeHtml(currentValue)}</option>`
    }
    
    return options
  }

  refreshAllTransitions() {
    const transitionControllers = this.application.controllers.filter(c => c.identifier === "step-transitions")
    transitionControllers.forEach(controller => {
      if (typeof controller.refresh === 'function') {
        controller.refresh()
      }
    })
  }

  // Refresh all step-selector controllers after any step mutation or reorder
  refreshAllDropdowns() {
    if (!this.hasContainerTarget) return

    const stepSelectors = this.containerTarget.querySelectorAll('[data-controller*="step-selector"]')
    stepSelectors.forEach(element => {
      const controller = this.application.getControllerForElementAndIdentifier(element, "step-selector")
      if (controller && typeof controller.refresh === 'function') {
        controller.refresh()
      }
    })
  }

  updateOrder(event) {
    this.updateAllStepIndices()
    this.refreshAllDropdowns()
    this.notifyPreviewUpdate()
  }

  addStep(event) {
    event.preventDefault()
    event.stopPropagation()

    const stepType = event.params.type
    if (!stepType) {
      console.error("[WorkflowBuilder] addStep: no step type provided")
      return
    }

    const stepData = {
      title: "",
      description: "",
      ...(this.constructor.STEP_DEFAULTS[stepType] || {})
    }

    this.addStepFromModal(stepType, stepData)
  }

  async addStepFromModal(stepType, stepData, insertAtIndex = null) {
    if (!this.hasContainerTarget) {
      this.warn("[WorkflowBuilder] No container target found")
      return
    }

    this.setLoading(true)
    try {
      // Remove empty state if present
      this.removeEmptyState()

      const existingSteps = this.containerTarget.querySelectorAll(".step-item")
      const totalSteps = existingSteps.length

      // Determine where to insert
      const insertIndex = insertAtIndex !== null ? Math.min(insertAtIndex, totalSteps) : totalSteps

      // Get workflow ID for server-side rendering
      const workflowId = this.getWorkflowIdFromPage()
      this.log(`[WorkflowBuilder] Adding step: type=${stepType}, index=${insertIndex}`)
      this.log(`[WorkflowBuilder] Workflow ID from page: ${workflowId}`)
      this.log(`[WorkflowBuilder] Has workflowIdValue: ${this.hasWorkflowIdValue}, value: ${this.workflowIdValue}`)

      let stepHtml
      let usedServerRendering = false

      // Try server-side rendering if we have a workflow ID
      if (workflowId) {
        try {
          this.log("[WorkflowBuilder] Attempting server-side rendering...")
          stepHtml = await this.fetchStepHtml(workflowId, stepType, insertIndex, stepData)
          this.log("[WorkflowBuilder] Server-side rendering successful, HTML length:", stepHtml.length)
          usedServerRendering = true
        } catch (error) {
          this.warn("[WorkflowBuilder] Server-side rendering failed:", error.message)
          this.warn("[WorkflowBuilder] Falling back to client-side rendering")
          stepHtml = buildStepHtml(this, stepType, insertIndex, stepData)
        }
      } else {
        // Fallback to client-side rendering for new workflows
        this.log("[WorkflowBuilder] No workflow ID found, using client-side rendering")
        this.log("[WorkflowBuilder] URL:", window.location.pathname)
        this.log("[WorkflowBuilder] Element:", this.element?.id || 'no-id')
        stepHtml = buildStepHtml(this, stepType, insertIndex, stepData)
      }

      this.log(`[WorkflowBuilder] Inserting step (server=${usedServerRendering}), HTML preview:`, stepHtml.substring(0, 200))

      // Insert at the specified position
      if (insertAtIndex !== null && insertAtIndex < totalSteps) {
        // Insert before the step at insertAtIndex
        const referenceStep = existingSteps[insertAtIndex]
        referenceStep.insertAdjacentHTML("beforebegin", stepHtml)
      } else {
        // Insert at the end
        this.containerTarget.insertAdjacentHTML("beforeend", stepHtml)
      }

      // Wait for Stimulus to connect controllers in the new HTML
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))

      // Update indices for all steps
      this.updateAllStepIndices()

      // Refresh dropdowns after adding new step
      this.refreshAllDropdowns()
      this.refreshAllRuleBuilders()
      this.refreshAllTransitions()
      this.notifyPreviewUpdate()

      // Dispatch events
      const stepElement = this.containerTarget.querySelector(`[data-step-index="${insertIndex}"]`)
      const extractedStepData = this.extractStepData(stepElement)
      document.dispatchEvent(new CustomEvent("workflow-builder:step-added", {
        detail: { stepIndex: insertIndex, stepType, stepData: extractedStepData }
      }))

      // Also dispatch for step outline to refresh
      document.dispatchEvent(new CustomEvent("workflow:updated"))

      // Scroll the new step into view and expand it
      if (stepElement) {
        stepElement.scrollIntoView({ behavior: "smooth", block: "center" })

        // Highlight the new step briefly
        stepElement.classList.add("ring-2", "ring-blue-500", "ring-offset-2")
        setTimeout(() => {
          stepElement.classList.remove("ring-2", "ring-blue-500", "ring-offset-2")
        }, 1500)
      }
    } finally {
      this.setLoading(false)
    }
  }

  setLoading(isLoading) {
    if (this.hasContainerTarget) {
      this.containerTarget.classList.toggle('opacity-50', isLoading)
      this.containerTarget.classList.toggle('pointer-events-none', isLoading)
    }
    const addButtons = this.element.querySelectorAll('[data-action*="addStepDirect"], [data-action*="addStep"]')
    addButtons.forEach(btn => { btn.disabled = isLoading })
  }
  
  /**
   * Fetch step HTML from the server (Sprint 3)
   * This enables server-side rendering with all the new features
   */
  async fetchStepHtml(workflowId, stepType, stepIndex, stepData = {}) {
    const url = `/workflows/${workflowId}/render_step`
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    this.log(`[WorkflowBuilder] Fetching step HTML from ${url}`)
    this.log(`[WorkflowBuilder] CSRF Token present: ${!!csrfToken}`)

    const requestBody = {
      step_type: stepType,
      step_index: stepIndex,
      step_data: stepData
    }
    this.log("[WorkflowBuilder] Request body:", requestBody)

    try {
      const response = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': csrfToken || '',
          'Accept': 'text/html'
        },
        credentials: 'same-origin', // Ensure cookies are sent
        body: JSON.stringify(requestBody)
      })

      this.log(`[WorkflowBuilder] Server response status: ${response.status}`)

      if (!response.ok) {
        const errorText = await response.text()
        console.error(`[WorkflowBuilder] Server error response:`, errorText.substring(0, 500))
        throw new Error(`Server returned ${response.status}`)
      }

      const html = await response.text()
      this.log(`[WorkflowBuilder] Received HTML (${html.length} chars)`)

      // Validate that we got actual step HTML, not an error page
      if (!html.includes('step-item') && !html.includes('data-step-index')) {
        this.warn('[WorkflowBuilder] Response does not appear to be valid step HTML')
        throw new Error('Invalid step HTML response')
      }

      return html
    } catch (fetchError) {
      console.error('[WorkflowBuilder] Fetch error:', fetchError.message)
      throw fetchError
    }
  }
  
  /**
   * Get workflow ID from the current page
   */
  getWorkflowIdFromPage() {
    // First, try getting from Stimulus value (most reliable)
    if (this.hasWorkflowIdValue && this.workflowIdValue) {
      return this.workflowIdValue.toString()
    }
    
    // Try getting from URL
    const urlMatch = window.location.pathname.match(/\/workflows\/(\d+)/)
    if (urlMatch) {
      return urlMatch[1]
    }
    
    // Try getting from form action
    const form = this.element.closest("form")
    if (form) {
      const actionMatch = form.action?.match(/\/workflows\/(\d+)/)
      if (actionMatch) {
        return actionMatch[1]
      }
    }
    
    return null
  }
  
  /**
   * Update all step indices after insertion or removal
   */
  updateAllStepIndices() {
    const stepItems = this.containerTarget.querySelectorAll(".step-item")
    stepItems.forEach((stepItem, index) => {
      // Update data attribute
      stepItem.dataset.stepIndex = index
      
      // Update hidden index input
      const indexInput = stepItem.querySelector("input[name*='[index]']")
      if (indexInput) {
        indexInput.value = index
      }
      
      // Update step number display in collapsible header
      const stepNumber = stepItem.querySelector(".step-number, .rounded-full.bg-white\\/20")
      if (stepNumber) {
        stepNumber.textContent = index + 1
      }
    })
  }

  removeStep(event) {
    event.preventDefault()
    event.stopPropagation()
    
    const stepElement = event.target.closest("[data-step-index]")
    if (stepElement) {
      const stepIndex = parseInt(stepElement.getAttribute("data-step-index") || stepElement.querySelector("input[name*='[index]']")?.value || "0")
      
      // Dispatch event for collaboration before removing
      document.dispatchEvent(new CustomEvent("workflow-builder:step-removed", {
        detail: { stepIndex }
      }))
      
      stepElement.remove()
      this.updateAllStepIndices()
      this.refreshAllDropdowns()
      this.refreshAllRuleBuilders()
      this.refreshAllTransitions()
      this.notifyPreviewUpdate()
    }
  }

  getTemplatesFromPage() {
    const scriptTag = document.getElementById('step-templates-data')
    if (!scriptTag) return { question: [], action: [] }
    
    try {
      return JSON.parse(scriptTag.textContent)
    } catch (e) {
      console.error("Failed to parse step templates:", e)
      return { question: [], action: [] }
    }
  }

  /**
   * Remove the empty state message when steps are added
   */
  removeEmptyState() {
    if (!this.hasContainerTarget) return

    // Find and remove the empty state div (contains "No steps yet" text)
    const emptyState = this.containerTarget.querySelector('.text-center.py-12')
    if (emptyState && emptyState.textContent.includes('No steps yet')) {
      emptyState.remove()
    }
  }

  extractStepData(stepElement) {
    if (!stepElement) return {}
    
    const data = {}
    
    // Extract title
    const titleInput = stepElement.querySelector("input[name*='[title]']")
    if (titleInput) data.title = titleInput.value
    
    // Extract description
    const descInput = stepElement.querySelector("textarea[name*='[description]']")
    if (descInput) data.description = descInput.value
    
    // Extract type-specific fields
    const typeInput = stepElement.querySelector("input[name*='[type]']")
    if (typeInput) data.type = typeInput.value
    
    if (data.type === "question") {
      const questionInput = stepElement.querySelector("input[name*='[question]']")
      if (questionInput) data.question = questionInput.value
      
      const answerTypeInput = stepElement.querySelector("input[name*='[answer_type]']")
      if (answerTypeInput) data.answer_type = answerTypeInput.value
      
      const variableInput = stepElement.querySelector("input[name*='[variable_name]']")
      if (variableInput) data.variable_name = variableInput.value
    } else if (data.type === "action") {
      const instructionsInput = stepElement.querySelector("textarea[name*='[instructions]']")
      if (instructionsInput) data.instructions = instructionsInput.value
    }
    
    return data
  }

  log(...args) {
    if (this.debugValue) console.log(...args)
  }

  warn(...args) {
    if (this.debugValue) console.warn(...args)
  }
}
