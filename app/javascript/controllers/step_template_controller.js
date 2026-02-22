import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["select"]
  static values = {
    stepType: String
  }

  connect() {
    // Get templates from data attribute
    this.parseTemplates()
    // Load templates for this step type
    this.loadTemplates()
  }

  parseTemplates() {
    // Get templates from data attribute
    // Stimulus converts kebab-case data attributes to camelCase
    // So data-step-template-templates-data becomes dataset.stepTemplateTemplatesData
    let templatesData = this.element.dataset.stepTemplateTemplatesData
    
    // Debug: log all dataset properties
    console.log("Step Template Controller - All dataset properties:", Object.keys(this.element.dataset))
    console.log("Step Template Controller - stepTemplateTemplatesData value:", templatesData)
    
    if (!templatesData) {
      console.error("Step Template Controller - No templates data found")
      // Try alternative access methods
      templatesData = this.element.getAttribute('data-step-template-templates-data')
      console.log("Step Template Controller - Trying getAttribute:", templatesData)
      if (!templatesData) {
        this.templatesValue = []
        return
      }
    }
    
    // dataset does NOT automatically decode HTML entities
    // We need to decode &quot; -> " and &#39; -> ' manually
    const textarea = document.createElement('textarea')
    textarea.innerHTML = templatesData
    const decodedData = textarea.value
    
    try {
      this.templatesValue = JSON.parse(decodedData)
      console.log("Step Template Controller - Templates loaded:", this.templatesValue)
    } catch (e) {
      console.error("Failed to parse templates JSON:", e)
      console.error("Raw templatesData:", templatesData)
      console.error("Decoded data:", decodedData)
      console.error("First 200 chars decoded:", decodedData.substring(0, 200))
      this.templatesValue = []
    }
  }

  loadTemplates() {
    const templates = this.templatesValue || []
    
    if (!this.hasSelectTarget) {
      console.warn("Step Template Controller - No select target found")
      return
    }
    
    // Clear existing options
    this.selectTarget.innerHTML = '<option value="">-- Select a template --</option>'
    
    // Add template options
    templates.forEach(template => {
      const option = document.createElement('option')
      option.value = template.key
      option.textContent = template.name
      this.selectTarget.appendChild(option)
    })
    
    console.log(`Step Template Controller - Loaded ${templates.length} templates`)
  }

  applyTemplate(event) {
    const templateKey = event.target.value
    if (!templateKey) return
    
    console.log("Step Template Controller - Applying template:", templateKey)
    console.log("Step Template Controller - Available templates:", this.templatesValue)
    
    const template = this.templatesValue.find(t => t.key === templateKey)
    if (!template) {
      console.error("Step Template Controller - Template not found:", templateKey)
      return
    }
    
    console.log("Step Template Controller - Found template:", template)
    
    // Apply template to the step form
    this.fillStepFields(template)
    
    // Reset select to show placeholder
    event.target.value = ""
  }

  fillStepFields(template) {
    console.log("Step Template Controller - Filling step fields with template:", template)
    
    // Find the step item by traversing up the DOM tree
    // The step item should have class 'step-item' and be a parent of this controller
    const stepItem = this.element.closest('.step-item')
    if (!stepItem) {
      console.error("Step Template Controller - Could not find step item")
      return
    }
    
    console.log("Step Template Controller - Found step item:", stepItem)
    
    // Fill title
    const titleInput = stepItem.querySelector("input[name*='[title]']")
    if (titleInput && template.title) {
      console.log("Step Template Controller - Filling title:", template.title)
      titleInput.value = template.title
      titleInput.dispatchEvent(new Event('input', { bubbles: true }))
    } else {
      console.warn("Step Template Controller - Title input not found or template.title missing", titleInput, template.title)
    }
    
    // Fill description
    const descriptionInput = stepItem.querySelector("textarea[name*='[description]']")
    if (descriptionInput && template.description) {
      console.log("Step Template Controller - Filling description:", template.description)
      descriptionInput.value = template.description
      descriptionInput.dispatchEvent(new Event('input', { bubbles: true }))
    } else {
      console.warn("Step Template Controller - Description input not found or template.description missing")
    }
    
    // Fill type-specific fields
    if (template.type === 'question') {
      this.fillQuestionFields(stepItem, template)
    } else if (template.type === 'action') {
      this.fillActionFields(stepItem, template)
    }
    
    // Trigger preview update
    this.notifyPreviewUpdate()
  }

  fillQuestionFields(stepItem, template) {
    console.log("Step Template Controller - Filling question fields:", template)
    
    // Fill question text
    const questionInput = stepItem.querySelector("input[name*='[question]']")
    if (questionInput && template.question) {
      console.log("Step Template Controller - Filling question:", template.question)
      questionInput.value = template.question
      questionInput.dispatchEvent(new Event('input', { bubbles: true }))
    } else {
      console.warn("Step Template Controller - Question input not found or template.question missing", questionInput, template.question)
    }
    
    // Set answer type
    if (template.answer_type) {
      console.log("Step Template Controller - Setting answer type:", template.answer_type)
      const answerTypeRadio = stepItem.querySelector(`input[name*='[answer_type]'][value='${template.answer_type}']`)
      if (answerTypeRadio) {
        answerTypeRadio.checked = true
        answerTypeRadio.dispatchEvent(new Event('change', { bubbles: true }))
        
        // Also update hidden field
        const hiddenAnswerType = stepItem.querySelector("input[name*='[answer_type]'][type='hidden']")
        if (hiddenAnswerType) {
          hiddenAnswerType.value = template.answer_type
        }
      } else {
        console.warn("Step Template Controller - Answer type radio not found:", template.answer_type)
      }
    }
    
    // Fill variable name
    const variableInput = stepItem.querySelector("input[name*='[variable_name]']")
    if (variableInput && template.variable_name) {
      console.log("Step Template Controller - Filling variable name:", template.variable_name)
      variableInput.value = template.variable_name
      variableInput.dispatchEvent(new Event('input', { bubbles: true }))
    } else {
      console.warn("Step Template Controller - Variable input not found or template.variable_name missing")
    }
    
    // Fill options if present
    if (template.options && Array.isArray(template.options) && template.options.length > 0) {
      const questionForm = stepItem.querySelector('[data-controller*="question-form"]')
      if (questionForm) {
        const optionsList = questionForm.querySelector('[data-question-form-target="optionsList"]')
        if (optionsList) {
          // Clear existing options
          optionsList.innerHTML = ''
          
          // Add template options
          template.options.forEach(option => {
            const label = option.label || option.value || option
            const value = option.value || option.label || option
            const escapedLabel = this.escapeHtml(String(label))
            const escapedValue = this.escapeHtml(String(value))
            const optionHtml = `
              <div class="flex gap-2 items-center option-item">
                <span class="drag-handle cursor-move text-gray-500 text-lg flex-shrink-0" title="Drag to reorder">☰</span>
                <input type="text"
                       name="workflow[steps][][options][][label]"
                       value="${escapedLabel}"
                       placeholder="Option label"
                       class="flex-1 border rounded px-2 py-1 text-sm min-w-0"
                       data-step-form-target="field">
                <input type="text"
                       name="workflow[steps][][options][][value]"
                       value="${escapedValue}"
                       placeholder="Option value"
                       class="flex-1 border rounded px-2 py-1 text-sm min-w-0"
                       data-step-form-target="field">
                <button type="button"
                        class="text-red-500 hover:text-red-700 text-sm px-2 flex-shrink-0"
                        data-action="click->question-form#removeOption">
                  Remove
                </button>
              </div>
            `
            optionsList.insertAdjacentHTML('beforeend', optionHtml)
          })
          
          // Show options container if it was hidden
          const optionsContainer = questionForm.querySelector('[data-question-form-target="optionsContainer"]')
          if (optionsContainer) {
            optionsContainer.classList.remove('hidden')
          }
        }
      }
    }
  }

  fillActionFields(stepItem, template) {
    // Fill action type
    const actionTypeInput = stepItem.querySelector("input[name*='[action_type]']")
    if (actionTypeInput && template.action_type) {
      actionTypeInput.value = template.action_type
    }
    
    // Fill instructions
    const instructionsInput = stepItem.querySelector("textarea[name*='[instructions]']")
    if (instructionsInput && template.instructions) {
      instructionsInput.value = template.instructions
    }
  }


  notifyPreviewUpdate() {
    // Dispatch event for preview updater
    this.element.dispatchEvent(new CustomEvent("workflow-steps-changed", { bubbles: true }))
    
    // Also trigger workflow builder update
    const workflowBuilder = document.querySelector("[data-controller*='workflow-builder']")
    if (workflowBuilder) {
      workflowBuilder.dispatchEvent(new CustomEvent("workflow:updated"))
    }
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}

