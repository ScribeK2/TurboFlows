import { Controller } from "@hotwired/stimulus"

// Step modal controller for guided step addition
export default class extends Controller {
  static targets = ["modalContainer", "stepType", "templateSelect", "form", "variableSuggest"]
  static values = {
    workflowId: Number,
    templatesData: Object
  }

  connect() {
    console.log("Step modal controller connected")
    // Load templates data from script tag if available
    const templatesScript = document.getElementById("step-templates-data")
    if (templatesScript) {
      try {
        this.templatesDataValue = JSON.parse(templatesScript.textContent)
      } catch (e) {
        console.error("Failed to parse templates data:", e)
      }
    }
    
    // Listen for edit step events from wizard flow preview
    this.boundHandleEditStep = this.handleEditStepFromPreview.bind(this)
    document.addEventListener("wizard-flow-preview:edit-step", this.boundHandleEditStep)
    
    // Initialize: show question fields by default
    this.showTypeSpecificFields("question")
  }

  disconnect() {
    if (this.boundHandleEditStep) {
      document.removeEventListener("wizard-flow-preview:edit-step", this.boundHandleEditStep)
    }
  }

  handleEditStepFromPreview(event) {
    const { stepIndex, step, workflowId } = event.detail
    // Navigate to step2 to edit the step
    if (workflowId) {
      Turbo.visit(`/workflows/${workflowId}/step2#step-${stepIndex}`)
    }
  }

  open(event) {
    event.preventDefault()
    console.log("Step modal open called", event)
    // Get step type from Stimulus params or button dataset
    const stepType = event.params?.type || event.currentTarget?.dataset?.stepModalTypeParam || event.currentTarget?.dataset?.type || "question"
    console.log("Step type:", stepType)
    this.currentStepType = stepType
    this.showModal(stepType)
  }

  showModal(stepType) {
    console.log("showModal called with stepType:", stepType)
    // Show the modal container
    const modalContainer = this.hasModalContainerTarget ? this.modalContainerTarget : document.getElementById("step-modal")
    console.log("Modal container found:", !!modalContainer)
    if (modalContainer) {
      modalContainer.classList.remove("hidden")
      
      // Use requestAnimationFrame to ensure DOM is ready
      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          // Manually find and cache form reference - try multiple methods
          const form = modalContainer.querySelector("form#step-modal-form") ||
                       modalContainer.querySelector("form") ||
                       document.getElementById("step-modal-form") ||
                       document.querySelector("#step-modal form")
          if (form) {
            // Cache form reference for later use
            this._formElement = form
            // Ensure modal form doesn't interfere with main form submission
            form.setAttribute("novalidate", "novalidate")
            console.log("Form cached:", form, "Form ID:", form.id)
          }
          
          // Update step type first (this will update visual selection)
          this.updateStepType(stepType)
          this.loadVariables()
          
          // Focus first input
          const firstInput = modalContainer.querySelector("#modal-step-title")
          if (firstInput) {
            setTimeout(() => firstInput.focus(), 100)
          }
        })
      })
    } else {
      console.error("Modal container not found!")
    }
  }

  close(event) {
    event?.preventDefault()
    // Hide the modal container
    const modalContainer = this.hasModalContainerTarget ? this.modalContainerTarget : document.getElementById("step-modal")
    if (modalContainer) {
      modalContainer.classList.add("hidden")
      this.resetForm()
    }
  }

  updateStepType(event) {
    // Handle both event and direct stepType parameter
    const stepType = event?.params?.type || event?.target?.value || event
    this.currentStepType = stepType
    
    // Update radio button selection
    const modalContainer = this.hasModalContainerTarget ? this.modalContainerTarget : document.getElementById("step-modal")
    if (modalContainer) {
      const radioButton = modalContainer.querySelector(`input[name="step_type"][value="${stepType}"]`)
      if (radioButton) {
        radioButton.checked = true
        // Update visual selection styling
        this.updateStepTypeVisualSelection(stepType)
      }
    }
    
    if (this.hasStepTypeTarget) {
      this.stepTypeTarget.value = stepType
      // Update template options based on step type
      this.updateTemplateOptions(stepType)
    }
    // Show/hide type-specific fields
    this.showTypeSpecificFields(stepType)
  }

  updateStepTypeVisualSelection(stepType) {
    const modalContainer = this.hasModalContainerTarget ? this.modalContainerTarget : document.getElementById("step-modal")
    if (!modalContainer) return
    
    // Remove all active styling from all step type options
    const allOptions = modalContainer.querySelectorAll(".step-type-option")
    allOptions.forEach(option => {
      const color = option.dataset.stepTypeColor || "blue"
      option.className = `flex flex-col items-center gap-1 p-3 border-2 rounded-lg cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-800 transition-colors border-gray-300 dark:border-gray-600 step-type-option`
    })
    
    // Add active styling to selected option
    const selectedOption = modalContainer.querySelector(`.step-type-option[data-step-type-option="${stepType}"]`)
    if (selectedOption) {
      const color = selectedOption.dataset.stepTypeColor || "blue"
      const colorMap = {
        blue: "border-blue-500 bg-blue-50 dark:bg-blue-900/20",
        green: "border-green-500 bg-green-50 dark:bg-green-900/20",
        purple: "border-purple-500 bg-purple-50 dark:bg-purple-900/20",
        yellow: "border-yellow-500 bg-yellow-50 dark:bg-yellow-900/20"
      }
      selectedOption.className = `flex flex-col items-center gap-1 p-3 border-2 rounded-lg cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-800 transition-colors ${colorMap[color] || colorMap.blue} step-type-option`
    }
  }

  showTypeSpecificFields(stepType) {
    // Hide all type-specific field containers
    const fieldContainers = {
      question: document.getElementById("question-fields"),
      action: document.getElementById("action-fields"),
      message: document.getElementById("message-fields"),
      sub_flow: document.getElementById("sub_flow-fields")
    }
    
    Object.values(fieldContainers).forEach(container => {
      if (container) container.classList.add("hidden")
    })
    
    // Show the selected type's fields
    if (fieldContainers[stepType]) {
      fieldContainers[stepType].classList.remove("hidden")
    }
  }

  updateTemplateOptions(stepType) {
    if (!this.hasTemplateSelectTarget) return
    
    const templates = this.templatesDataValue?.[stepType] || []
    const select = this.templateSelectTarget
    
    // Clear existing options except the first one
    while (select.options.length > 1) {
      select.remove(1)
    }
    
    // Add templates for this step type
    templates.forEach(template => {
      const option = document.createElement("option")
      option.value = template.key
      option.textContent = template.name
      select.appendChild(option)
    })
    
    // Reset selection
    select.value = ""
  }

  applyTemplate(event) {
    const templateKey = event.target.value
    if (!templateKey) return
    
    const stepType = this.currentStepType || this.stepTypeTarget?.value
    const templates = this.templatesDataValue?.[stepType] || []
    const template = templates.find(t => t.key === templateKey)
    
    if (!template) return
    
    // Find form from event target (more reliable)
    const form = event.target.closest("form") ||
                 event.target.closest("#step-modal")?.querySelector("form") ||
                 this._formElement ||
                 document.getElementById("step-modal-form")
    
    if (form && !this._formElement) {
      this._formElement = form
      console.log("Form cached from applyTemplate:", form)
    }
    
    // Pre-fill form fields based on template
    this.prefillFromTemplate(template)
  }

  prefillFromTemplate(template) {
    console.log("Prefilling from template:", template)
    // Use cached form or find it immediately
    const modalContainer = this.hasModalContainerTarget ? this.modalContainerTarget : document.getElementById("step-modal")
    const form = this._formElement ||
                 (modalContainer ? modalContainer.querySelector("form#step-modal-form") : null) ||
                 (modalContainer ? modalContainer.querySelector("form") : null) ||
                 document.getElementById("step-modal-form") || 
                 document.querySelector("#step-modal form") ||
                 document.querySelector("form#step-modal-form")
    console.log("Form lookup result:", form, "Modal container:", modalContainer, "Cached:", this._formElement)
    if (!form) {
      console.error("Form not found for template prefill", {
        cached: this._formElement,
        modalContainer: modalContainer,
        formInModal: modalContainer ? modalContainer.querySelector("form") : null,
        byId: document.getElementById("step-modal-form"),
        byQuery: document.querySelector("#step-modal form"),
        modalExists: !!document.getElementById("step-modal"),
        modalHTML: modalContainer ? modalContainer.innerHTML.substring(0, 500) : null
      })
      return
    }
    
    // Get step type from template (could be 'type' or check current step type)
    const stepType = template.type || this.currentStepType || form.querySelector("input[name='step_type']:checked")?.value || "question"
    console.log("Step type for template:", stepType)
    
    // Pre-fill common fields
    const titleInput = form.querySelector("#modal-step-title")
    if (titleInput && template.title) {
      titleInput.value = template.title
      titleInput.dispatchEvent(new Event('input', { bubbles: true }))
      console.log("Set title:", template.title)
    }
    
    const descInput = form.querySelector("#modal-step-description")
    if (descInput && template.description) {
      descInput.value = template.description
      descInput.dispatchEvent(new Event('input', { bubbles: true }))
      console.log("Set description:", template.description)
    }
    
    // Pre-fill type-specific fields
    if (stepType === "question") {
      const questionInput = form.querySelector("#modal-step-question")
      if (questionInput && template.question) {
        questionInput.value = template.question
        questionInput.dispatchEvent(new Event('input', { bubbles: true }))
        console.log("Set question:", template.question)
      }
      
      const answerTypeSelect = form.querySelector("#modal-step-answer-type")
      if (answerTypeSelect && template.answer_type) {
        answerTypeSelect.value = template.answer_type
        answerTypeSelect.dispatchEvent(new Event('change', { bubbles: true }))
        console.log("Set answer_type:", template.answer_type)
      }
      
      const varInput = form.querySelector("#modal-step-variable-name")
      if (varInput && template.variable_name) {
        varInput.value = template.variable_name
        varInput.dispatchEvent(new Event('input', { bubbles: true }))
        console.log("Set variable_name:", template.variable_name)
      }
    } else if (stepType === "action") {
      const actionTypeInput = form.querySelector("#modal-step-action-type")
      if (actionTypeInput && template.action_type) {
        actionTypeInput.value = template.action_type
        actionTypeInput.dispatchEvent(new Event('input', { bubbles: true }))
        console.log("Set action_type:", template.action_type)
      }
      
      const instructionsInput = form.querySelector("#modal-step-instructions")
      if (instructionsInput && template.instructions) {
        instructionsInput.value = template.instructions
        instructionsInput.dispatchEvent(new Event('input', { bubbles: true }))
        console.log("Set instructions:", template.instructions)
      }
    }
  }

  async loadVariables() {
    if (!this.workflowIdValue) return
    
    try {
      const response = await fetch(`/workflows/${this.workflowIdValue}/variables.json`)
      const data = await response.json()
      
      if (data.variables && Array.isArray(data.variables)) {
        this.updateVariableSuggestions(data.variables)
      }
    } catch (error) {
      console.error("Failed to load variables:", error)
    }
  }

  updateVariableSuggestions(variables) {
    if (!this.hasVariableSuggestTarget) return
    
    const container = this.variableSuggestTarget
    container.innerHTML = ""
    
    if (variables.length === 0) {
      container.innerHTML = '<p class="text-xs text-gray-500">No variables available yet</p>'
      return
    }
    
    const label = document.createElement("label")
    label.className = "block text-xs font-medium text-gray-700 mb-1"
    label.textContent = "Available Variables:"
    container.appendChild(label)
    
    const list = document.createElement("div")
    list.className = "flex flex-wrap gap-1"
    
    variables.forEach(variable => {
      const badge = document.createElement("span")
      badge.className = "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 cursor-pointer hover:bg-gray-200 dark:hover:bg-gray-600"
      badge.textContent = variable
      badge.dataset.variable = variable
      badge.addEventListener("click", () => this.insertVariable(variable))
      list.appendChild(badge)
    })
    
    container.appendChild(list)
  }

  insertVariable(variable) {
    // Find variable name input and insert variable
    const form = this._formElement ||
                 document.getElementById("step-modal-form") || 
                 document.querySelector("#step-modal form") ||
                 (this.hasFormTarget ? this.formTarget : null)
    if (!form) return
    
    const varInput = form.querySelector("#modal-step-variable-name")
    if (varInput) {
      varInput.value = variable
      varInput.focus()
    }
  }

  resetForm() {
    const form = this._formElement ||
                 document.getElementById("step-modal-form") || 
                 document.querySelector("#step-modal form") ||
                 (this.hasFormTarget ? this.formTarget : null)
    const modalContainer = this.hasModalContainerTarget ? this.modalContainerTarget : document.getElementById("step-modal")
    if (form) {
      form.reset()
      // Reset template select
      if (this.hasTemplateSelectTarget) {
        this.templateSelectTarget.value = ""
      }
      // Reset to question type
      const questionRadio = modalContainer ? modalContainer.querySelector(`input[name="step_type"][value="question"]`) : null
      if (questionRadio) {
        questionRadio.checked = true
        this.updateStepTypeVisualSelection("question")
        this.showTypeSpecificFields("question")
      }
      // Clear cached form reference and reset current step type
      this._formElement = null
      this.currentStepType = "question"
    }
  }

  backdropClick(event) {
    const modalContainer = this.hasModalContainerTarget ? this.modalContainerTarget : document.getElementById("step-modal")
    const backdrop = modalContainer?.querySelector('[data-step-modal-target="backdrop"]')
    // Only close if clicking directly on the backdrop or the modal container itself (not on modal content)
    if (modalContainer && (event.target === modalContainer || event.target === backdrop)) {
      this.close(event)
    }
  }

  stopPropagation(event) {
    // Prevent clicks on modal content from bubbling up to backdrop
    event.stopPropagation()
  }

  addStep(event) {
    event.preventDefault()
    console.log("Add step button clicked")
    
    // Get modal container first
    const modalContainer = this.hasModalContainerTarget ? this.modalContainerTarget : document.getElementById("step-modal")
    
    // Query form - try finding from event target first (most reliable)
    const form = event.target.closest("form") ||
                 event.target.closest("#step-modal")?.querySelector("form") ||
                 this._formElement || 
                 (modalContainer ? modalContainer.querySelector("form#step-modal-form") : null) ||
                 (modalContainer ? modalContainer.querySelector("form") : null) ||
                 document.getElementById("step-modal-form") || 
                 document.querySelector("#step-modal form") ||
                 document.querySelector("form#step-modal-form") ||
                 (this.hasFormTarget ? this.formTarget : null)
    
    // Cache form if found
    if (form && !this._formElement) {
      this._formElement = form
      console.log("Form cached from addStep:", form)
    }
    console.log("Form lookup:", {
      cached: this._formElement,
      modalContainer: modalContainer,
      formInModal: modalContainer ? modalContainer.querySelector("form") : null,
      byId: document.getElementById("step-modal-form"),
      byQuery1: document.querySelector("#step-modal form"),
      byQuery2: document.querySelector("form#step-modal-form"),
      byTarget: this.hasFormTarget ? this.formTarget : null,
      finalForm: form
    })
    if (!form) {
      console.error("Form not found", {
        modalExists: !!document.getElementById("step-modal"),
        modalVisible: document.getElementById("step-modal")?.classList.contains("hidden") === false,
        modalHTML: modalContainer ? modalContainer.innerHTML.substring(0, 500) : null
      })
      return
    }
    
    // Validate form manually (don't use checkValidity since modal form is hidden)
    const titleInput = form.querySelector("#modal-step-title")
    if (!titleInput || !titleInput.value || !titleInput.value.trim()) {
      alert("Please enter a step title")
      if (titleInput) titleInput.focus()
      return
    }
    
    // Get step type
    const stepType = this.currentStepType || form.querySelector("input[name='step_type']:checked")?.value || "question"
    console.log("Step type:", stepType)
    
    // Extract form data
    const formData = new FormData(form)
    const stepData = {
      type: stepType,
      title: formData.get("title") || "",
      description: formData.get("description") || ""
    }
    
    // Add type-specific fields
    if (stepType === "question") {
      stepData.question = formData.get("question") || ""
      stepData.answer_type = formData.get("answer_type") || ""
      stepData.variable_name = formData.get("variable_name") || ""
    } else if (stepType === "action") {
      stepData.action_type = formData.get("action_type") || ""
      stepData.instructions = formData.get("instructions") || ""
    }
    
    console.log("Step data:", stepData)
    
    // Dispatch custom event to add step via workflow-builder
    const addStepEvent = new CustomEvent("step-modal:add-step", {
      detail: { stepType, stepData },
      bubbles: true
    })
    document.dispatchEvent(addStepEvent)
    console.log("Dispatched step-modal:add-step event", { stepType, stepData })
    
    // Close modal and reset form
    this.close()
  }

  updateNewlyAddedStep(stepData) {
    const workflowBuilder = document.querySelector("[data-controller*='workflow-builder']")
    if (!workflowBuilder) return
    
    const container = workflowBuilder.querySelector("[data-workflow-builder-target='container']")
    if (!container) return
    
    const lastStep = container.querySelector(".step-item:last-child")
    if (!lastStep) return
    
    // Update title
    const titleInput = lastStep.querySelector("input[name*='[title]']")
    if (titleInput && stepData.title) {
      titleInput.value = stepData.title
      titleInput.dispatchEvent(new Event('input', { bubbles: true }))
    }
    
    // Update description
    const descInput = lastStep.querySelector("textarea[name*='[description]']")
    if (descInput && stepData.description) {
      descInput.value = stepData.description
      descInput.dispatchEvent(new Event('input', { bubbles: true }))
    }
    
    // Update type-specific fields
    if (stepData.type === "question") {
      const questionInput = lastStep.querySelector("input[name*='[question]']")
      if (questionInput && stepData.question) {
        questionInput.value = stepData.question
        questionInput.dispatchEvent(new Event('input', { bubbles: true }))
      }
      
      if (stepData.answer_type) {
        const answerTypeInput = lastStep.querySelector(`input[name*='[answer_type]'][value="${stepData.answer_type}"]`)
        if (answerTypeInput) {
          answerTypeInput.checked = true
          answerTypeInput.dispatchEvent(new Event('change', { bubbles: true }))
        }
      }
      
      const varInput = lastStep.querySelector("input[name*='[variable_name]']")
      if (varInput && stepData.variable_name) {
        varInput.value = stepData.variable_name
        varInput.dispatchEvent(new Event('input', { bubbles: true }))
      }
    } else if (stepData.type === "action") {
      const actionTypeInput = lastStep.querySelector("input[name*='[action_type]']")
      if (actionTypeInput && stepData.action_type) {
        actionTypeInput.value = stepData.action_type
        actionTypeInput.dispatchEvent(new Event('input', { bubbles: true }))
      }
      
      const instructionsInput = lastStep.querySelector("textarea[name*='[instructions]']")
      if (instructionsInput && stepData.instructions) {
        instructionsInput.value = stepData.instructions
        instructionsInput.dispatchEvent(new Event('input', { bubbles: true }))
      }
    }
    
    // Scroll to the newly added step
    lastStep.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
  }
}

