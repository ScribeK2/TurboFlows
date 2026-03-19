import { Controller } from "@hotwired/stimulus"

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

      // Rich text editors (Trix) fire trix-change instead of input
      stepForm.addEventListener("trix-change", () => {
        this.updatePreview()
      })

      // Lexxy (Lexical) swallows input events — keyup is the only
      // reliable event that bubbles from its contenteditable
      stepForm.addEventListener("keyup", (e) => {
        if (e.target.closest("lexxy-editor")) {
          this.updatePreview()
        }
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
      this.refreshPreviewFrame()
    }, this.debounceDelay)
  }

  refreshPreviewFrame() {
    if (!this.hasPreviewFrameTarget || !this.urlValue) {
      return
    }

    const form = this.element.closest("form")
    if (!form) return

    // Extract step data from form
    const stepData = this.extractStepData(form)

    // Build URL with step data as query params
    const params = new URLSearchParams({
      step_index: this.indexValue || 0
    })

    Object.keys(stepData).forEach(key => {
      if (Array.isArray(stepData[key])) return

      if (stepData[key] !== null && stepData[key] !== undefined && stepData[key] !== "") {
        params.append(`step[${key}]`, stepData[key])
      }
    })

    if (stepData.options && Array.isArray(stepData.options)) {
      params.append("step[options]", JSON.stringify(stepData.options))
    }

    if (stepData.attachments !== undefined && Array.isArray(stepData.attachments)) {
      params.append("step[attachments]", JSON.stringify(stepData.attachments))
    }

    // Update the Turbo Frame src to trigger a Turbo-driven reload
    const frame = this.previewFrameTarget
    frame.src = `${this.urlValue}?${params}`
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

      // Rich text area stores content in a hidden input, not a textarea
      stepData.instructions = this.getRichTextOrPlain(stepContainer, "instructions")

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
      // Rich text area stores content in a hidden input, not a textarea
      stepData.content = this.getRichTextOrPlain(stepContainer, "content")

    } else if (stepData.type === "escalate") {
      const targetTypeInput = stepContainer.querySelector("input[name*='[target_type]']")
      stepData.target_type = targetTypeInput ? targetTypeInput.value : ""

      const targetValueInput = stepContainer.querySelector("input[name*='[target_value]']")
      stepData.target_value = targetValueInput ? targetValueInput.value : ""

      const prioritySelect = stepContainer.querySelector("select[name*='[priority]']")
      stepData.priority = prioritySelect ? prioritySelect.value : ""

      const reasonRequiredInput = stepContainer.querySelector("input[name*='[reason_required]'][type='checkbox']")
      stepData.reason_required = reasonRequiredInput ? reasonRequiredInput.checked.toString() : "false"

      stepData.notes = this.getRichTextOrPlain(stepContainer, "notes")

    } else if (stepData.type === "resolve") {
      const resolutionTypeInput = stepContainer.querySelector("input[name*='[resolution_type]']")
      stepData.resolution_type = resolutionTypeInput ? resolutionTypeInput.value : ""

      const resolutionCodeInput = stepContainer.querySelector("input[name*='[resolution_code]']")
      stepData.resolution_code = resolutionCodeInput ? resolutionCodeInput.value : ""

      const notesRequiredInput = stepContainer.querySelector("input[name*='[notes_required]'][type='checkbox']")
      stepData.notes_required = notesRequiredInput ? notesRequiredInput.checked.toString() : "false"

      const surveyTriggerInput = stepContainer.querySelector("input[name*='[survey_trigger]'][type='checkbox']")
      stepData.survey_trigger = surveyTriggerInput ? surveyTriggerInput.checked.toString() : "false"

    } else if (stepData.type === "sub_flow") {
      const targetWorkflowInput = stepContainer.querySelector("input[name*='[target_workflow_id]']")
      stepData.target_workflow_id = targetWorkflowInput ? targetWorkflowInput.value : ""
    }

    return stepData
  }

  /**
   * Extract content from a rich text area (Action Text) or plain textarea.
   * Rich text areas use a hidden input (set by trix-editor/Lexxy),
   * while plain fields use a textarea element.
   */
  getRichTextOrPlain(container, fieldName) {
    // Try Lexxy custom element (stores value in element.value property)
    const lexxyEditor = container.querySelector(`lexxy-editor[name*='[${fieldName}]']`)
    if (lexxyEditor && lexxyEditor.value) return lexxyEditor.value

    // Try trix/legacy: hidden input set by the rich text editor
    const hiddenInput = container.querySelector(`input[type="hidden"][name*='[${fieldName}]']`)
    if (hiddenInput && hiddenInput.value) return hiddenInput.value

    // Fallback: plain textarea
    const textarea = container.querySelector(`textarea[name*='[${fieldName}]']`)
    if (textarea) return textarea.value

    return ""
  }
}
