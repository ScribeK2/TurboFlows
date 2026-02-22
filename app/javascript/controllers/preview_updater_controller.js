import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  static values = { 
    url: String,
    index: Number 
  }
  
  static targets = ["previewFrame"]
  
  connect() {
    this.debounceDelay = 500 // ms
    this.setupEventListeners()
  }
  
  setupEventListeners() {
    // Listen for input events on form fields within this step
    const stepForm = this.element.closest(".step-item")
    if (stepForm) {
      stepForm.addEventListener("input", () => {
        this.updatePreview()
      })
      
      stepForm.addEventListener("change", () => {
        this.updatePreview()
      })
      
      // Also listen for custom workflow-steps-changed event
      stepForm.addEventListener("workflow-steps-changed", () => {
        this.updatePreview()
      })
    }
  }
  
  updatePreview() {
    clearTimeout(this.updateTimeout)
    this.updateTimeout = setTimeout(() => {
      this.fetchPreview()
    }, this.debounceDelay)
  }
  
  async fetchPreview() {
    if (!this.hasPreviewFrameTarget || !this.urlValue) {
      return
    }
    
    const form = this.element.closest("form")
    if (!form) return
    
    // Extract step data from form
    const stepData = this.extractStepData(form)
    
    // Build URL with step data
    const params = new URLSearchParams({
      step_index: this.indexValue || 0
    })
    
    // Add step data as JSON in query params
    // Skip arrays - they'll be handled separately
    Object.keys(stepData).forEach(key => {
      // Skip arrays - they'll be handled separately
      if (Array.isArray(stepData[key])) {
        return
      }
      
      if (stepData[key] !== null && stepData[key] !== undefined && stepData[key] !== "") {
        params.append(`step[${key}]`, stepData[key])
      }
    })
    
    // If step has options array, serialize it
    if (stepData.options && Array.isArray(stepData.options)) {
      params.append("step[options]", JSON.stringify(stepData.options))
    }
    
    // Always send attachments array (even if empty) so the preview knows about it
    if (stepData.attachments !== undefined && Array.isArray(stepData.attachments)) {
      params.append("step[attachments]", JSON.stringify(stepData.attachments))
    }
    
    try {
      const response = await fetch(`${this.urlValue}?${params}`, {
        method: "GET",
        headers: {
          "Accept": "text/vnd.turbo-stream.html, text/html",
          "X-Requested-With": "XMLHttpRequest"
        }
      })
      
      if (response.ok) {
        const html = await response.text()
        // Check if it's a Turbo Stream response
        if (html.includes("<turbo-stream")) {
          Turbo.renderStreamMessage(html)
        } else {
          // Regular HTML response - update the frame directly
          this.previewFrameTarget.innerHTML = html
        }
      }
    } catch (error) {
      console.error("Preview update failed:", error)
    }
  }
  
  extractStepData(form) {
    const stepData = {}
    const stepIndex = this.indexValue || 0
    
    // Find inputs within this step's container
    const stepContainer = this.element.closest(".step-item")
    if (!stepContainer) return stepData
    
    // Get step type
    const typeInput = stepContainer.querySelector("input[name*='[type]']")
    stepData.type = typeInput ? typeInput.value : ""
    
    // Get title
    const titleInput = stepContainer.querySelector("input[name*='[title]']")
    stepData.title = titleInput ? titleInput.value : ""
    
    // Get description (might be textarea or rich text)
    const descInput = stepContainer.querySelector("textarea[name*='[description]'], input[name*='[description]']")
    stepData.description = descInput ? descInput.value : ""
    
    // Type-specific fields
    if (stepData.type === "question") {
      const questionInput = stepContainer.querySelector("input[name*='[question]']")
      stepData.question = questionInput ? questionInput.value : ""
      
      const answerTypeInput = stepContainer.querySelector("input[name*='[answer_type]']:checked, input[name*='[answer_type]']")
      stepData.answer_type = answerTypeInput ? answerTypeInput.value : ""
      
      const variableInput = stepContainer.querySelector("input[name*='[variable_name]']")
      stepData.variable_name = variableInput ? variableInput.value : ""
      
      // Extract options for multiple choice/dropdown
      const options = []
      const optionInputs = stepContainer.querySelectorAll("input[name*='[options]']")
      optionInputs.forEach(input => {
        const nameMatch = input.name.match(/\[options\]\[(\d+)\]\[(\w+)\]/)
        if (nameMatch) {
          const index = parseInt(nameMatch[1])
          const field = nameMatch[2]
          
          if (!options[index]) {
            options[index] = {}
          }
          options[index][field] = input.value
        }
      })
      
      // Filter out empty options
      stepData.options = options.filter(opt => opt && (opt.label || opt.value))
      
    } else if (stepData.type === "action") {
      const actionTypeInput = stepContainer.querySelector("input[name*='[action_type]']")
      stepData.action_type = actionTypeInput ? actionTypeInput.value : ""
      
      const instructionsInput = stepContainer.querySelector("textarea[name*='[instructions]']")
      stepData.instructions = instructionsInput ? instructionsInput.value : ""
      
      // Extract attachments
      const attachmentsInput = stepContainer.querySelector("input[name*='[attachments]']")
      if (attachmentsInput && attachmentsInput.value) {
        try {
          stepData.attachments = JSON.parse(attachmentsInput.value)
        } catch (e) {
          stepData.attachments = []
        }
      } else {
        stepData.attachments = []
      }
      
    } else if (stepData.type === "message") {
      const contentInput = stepContainer.querySelector("textarea[name*='[content]']")
      stepData.content = contentInput ? contentInput.value : ""

    } else if (stepData.type === "escalate") {
      const targetTypeInput = stepContainer.querySelector("input[name*='[target_type]']")
      stepData.target_type = targetTypeInput ? targetTypeInput.value : ""

      const targetValueInput = stepContainer.querySelector("input[name*='[target_value]']")
      stepData.target_value = targetValueInput ? targetValueInput.value : ""

      const prioritySelect = stepContainer.querySelector("select[name*='[priority]']")
      stepData.priority = prioritySelect ? prioritySelect.value : ""

      const reasonRequiredInput = stepContainer.querySelector("input[name*='[reason_required]'][type='checkbox']")
      stepData.reason_required = reasonRequiredInput ? reasonRequiredInput.checked.toString() : "false"

      const notesInput = stepContainer.querySelector("textarea[name*='[notes]']")
      stepData.notes = notesInput ? notesInput.value : ""

    } else if (stepData.type === "resolve") {
      const resolutionTypeInput = stepContainer.querySelector("input[name*='[resolution_type]']")
      stepData.resolution_type = resolutionTypeInput ? resolutionTypeInput.value : ""

      const resolutionCodeInput = stepContainer.querySelector("input[name*='[resolution_code]']")
      stepData.resolution_code = resolutionCodeInput ? resolutionCodeInput.value : ""

      const notesRequiredInput = stepContainer.querySelector("input[name*='[notes_required]'][type='checkbox']")
      stepData.notes_required = notesRequiredInput ? notesRequiredInput.checked.toString() : "false"

      const surveyTriggerInput = stepContainer.querySelector("input[name*='[survey_trigger]'][type='checkbox']")
      stepData.survey_trigger = surveyTriggerInput ? surveyTriggerInput.checked.toString() : "false"
    }

    return stepData
  }
}

