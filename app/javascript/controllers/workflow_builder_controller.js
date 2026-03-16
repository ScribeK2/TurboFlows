import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"
import { STEP_DEFAULTS } from "services/step_defaults"

function escapeHtml(text) {
  const div = document.createElement("div")
  div.textContent = text
  return div.innerHTML
}

function getWorkflowIdFromForm(element) {
  const form = element.closest("form")
  if (!form) return null
  const action = form.action || ""
  const match = action.match(/\/workflows\/(\d+)/)
  return match ? match[1] : null
}

export default class extends Controller {
  static targets = ["container"]
  static values = {
    workflowId: Number,
    debug: { type: Boolean, default: false },
    graphMode: { type: Boolean, default: false },
    wizardNextUrl: { type: String, default: "" }
  }

  static STEP_DEFAULTS = STEP_DEFAULTS

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

    // Intercept form submit to save via sync_steps for existing workflows
    this.boundFormSubmit = async (e) => {
      const workflowId = this.workflowIdValue || getWorkflowIdFromForm(this.element)
      if (!workflowId) return // New workflow, let form submit normally

      // Defer to visual editor when it is active — it handles its own save
      const visualEditor = document.getElementById("visual-editor-container")
      if (visualEditor && !visualEditor.classList.contains("is-hidden")) {
        // Visual editor's own submit handler will take over
        return
      }

      e.preventDefault()
      const success = await this.saveToServer()
      if (success) {
        // In wizard mode, redirect to the next wizard step instead of show page
        const nextUrl = this.wizardNextUrlValue
        window.location.href = nextUrl || `/workflows/${workflowId}`
      }
    }
    const form = this.element.closest("form")
    if (form) {
      // Use capturing phase so our handler fires BEFORE Turbo's submit observer
      form.addEventListener("submit", this.boundFormSubmit, true)
    }
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
    if (this.boundFormSubmit) {
      const form = this.element.closest("form")
      if (form) form.removeEventListener("submit", this.boundFormSubmit, true)
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
          this.showError("Failed to add step. Please try again.")
          return
        }
      } else {
        this.warn("[WorkflowBuilder] No workflow ID found, cannot add step")
        this.showError("Please save the workflow first before adding steps.")
        return
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
        stepElement.classList.add("is-selected")
        setTimeout(() => {
          stepElement.classList.remove("is-selected")
        }, 1500)
      }
    } finally {
      this.setLoading(false)
    }
  }

  setLoading(isLoading) {
    if (this.hasContainerTarget) {
      this.containerTarget.classList.toggle('is-disabled', isLoading)
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
      const stepNumber = stepItem.querySelector(".step-number, .step-card__number")
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
    const emptyState = this.containerTarget.querySelector('[data-empty-state]')
    if (emptyState) {
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

  // Collect full step data from all DOM step elements for sync_steps submission
  collectStepsFromDOM() {
    const stepElements = this.containerTarget.querySelectorAll(".step-item")
    const steps = []

    stepElements.forEach((el, index) => {
      const idInput = el.querySelector("input[name*='[id]']")
      const typeInput = el.querySelector("input[name*='[type]']")
      if (!idInput || !typeInput) return

      const step = {
        id: idInput.value,
        type: typeInput.value,
        position: index
      }

      // Title
      const titleInput = el.querySelector("input[name*='[title]']")
      if (titleInput) step.title = titleInput.value

      // Transitions
      const transInput = el.querySelector("input[name*='[transitions_json]']")
      if (transInput && transInput.value) {
        try { step.transitions = JSON.parse(transInput.value) } catch { step.transitions = [] }
      } else {
        step.transitions = []
      }

      // Type-specific fields
      switch (step.type) {
        case "question": {
          const q = el.querySelector("input[name*='[question]'], textarea[name*='[question]']")
          if (q) step.question = q.value
          const at = el.querySelector("input[name*='[answer_type]']")
          if (at) step.answer_type = at.value
          const vn = el.querySelector("input[name*='[variable_name]']")
          if (vn) step.variable_name = vn.value
          // Options (multiple choice)
          const optLabels = el.querySelectorAll("input[name*='[options][][label]']")
          const optValues = el.querySelectorAll("input[name*='[options][][value]']")
          if (optLabels.length > 0) {
            step.options = Array.from(optLabels).map((label, i) => ({
              label: label.value,
              value: optValues[i]?.value || ""
            }))
          }
          break
        }
        case "action": {
          const inst = el.querySelector("textarea[name*='[instructions]']")
          // Also check for Action Text rich text (trix/lexxy editor)
          const richInst = el.querySelector("input[name*='[instructions]'][type='hidden'][id*='trix']") ||
                           el.querySelector("[name*='[instructions]']")
          if (inst) step.instructions = inst.value
          else if (richInst) step.instructions = richInst.value
          const cr = el.querySelector("input[name*='[can_resolve]']")
          if (cr) step.can_resolve = cr.value === "true" || cr.value === "1"
          break
        }
        case "message": {
          const content = el.querySelector("textarea[name*='[content]']") ||
                          el.querySelector("[name*='[content]']")
          if (content) step.content = content.value
          const cr = el.querySelector("input[name*='[can_resolve]']")
          if (cr) step.can_resolve = cr.value === "true" || cr.value === "1"
          break
        }
        case "escalate": {
          const tt = el.querySelector("select[name*='[target_type]'], input[name*='[target_type]']")
          if (tt) step.target_type = tt.value
          const tv = el.querySelector("input[name*='[target_value]']")
          if (tv) step.target_value = tv.value
          const p = el.querySelector("select[name*='[priority]']")
          if (p) step.priority = p.value
          const rr = el.querySelector("input[name*='[reason_required]']")
          if (rr) step.reason_required = rr.value === "true" || rr.value === "1"
          const notes = el.querySelector("textarea[name*='[notes]']") ||
                        el.querySelector("[name*='[notes]']")
          if (notes) step.notes = notes.value
          break
        }
        case "resolve": {
          const rt = el.querySelector("select[name*='[resolution_type]'], input[name*='[resolution_type]']")
          if (rt) step.resolution_type = rt.value
          const rc = el.querySelector("input[name*='[resolution_code]']")
          if (rc) step.resolution_code = rc.value
          const nr = el.querySelector("input[name*='[notes_required]']")
          if (nr) step.notes_required = nr.value === "true" || nr.value === "1"
          const st = el.querySelector("input[name*='[survey_trigger]']")
          if (st) step.survey_trigger = st.value === "true" || st.value === "1"
          break
        }
        case "sub_flow": {
          const twf = el.querySelector("select[name*='[target_workflow_id]'], input[name*='[target_workflow_id]']")
          if (twf) step.target_workflow_id = twf.value
          break
        }
      }

      steps.push(step)
    })

    return steps
  }

  async saveToServer() {
    const workflowId = this.workflowIdValue || getWorkflowIdFromForm(this.element)
    if (!workflowId) {
      console.error("[WorkflowBuilder] No workflow ID for sync_steps")
      return false
    }

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    const lockInput = this.element.closest("form")?.querySelector("input[name='workflow[lock_version]']")
    const lockVersion = lockInput ? parseInt(lockInput.value) : 0

    const steps = this.collectStepsFromDOM()
    const startInput = this.element.closest("form")?.querySelector("input[name='workflow[start_node_uuid]']")
    const startNodeUuid = startInput?.value || (steps[0]?.id || null)

    const payload = { steps, start_node_uuid: startNodeUuid, lock_version: lockVersion }

    try {
      const response = await fetch(`/workflows/${workflowId}/sync_steps`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken || "",
          "Accept": "application/json"
        },
        credentials: "same-origin",
        body: JSON.stringify(payload)
      })

      if (response.ok) {
        const data = await response.json()
        if (lockInput) lockInput.value = data.lock_version
        return true
      } else if (response.status === 409) {
        alert("This workflow was modified by another user. Please refresh and try again.")
        return false
      } else {
        const data = await response.json().catch(() => ({}))
        alert(data.error || "Failed to save workflow.")
        return false
      }
    } catch (error) {
      console.error("[WorkflowBuilder] Save failed:", error)
      alert("Network error. Please try again.")
      return false
    }
  }

  log(...args) {
    if (this.debugValue) console.log(...args)
  }

  warn(...args) {
    if (this.debugValue) console.warn(...args)
  }

  showError(message) {
    const statusEl = document.querySelector("[data-autosave-target='status']")
    if (statusEl) {
      statusEl.textContent = message
      statusEl.classList.add("status--error")
      setTimeout(() => {
        statusEl.textContent = "Ready to save"
        statusEl.classList.remove("status--error")
      }, 3000)
    }
  }
}
