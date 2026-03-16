import { Controller } from "@hotwired/stimulus"

// Step editing modal for the visual editor.
// Receives step data via visual-editor:open-modal event,
// dispatches visual-editor:step-saved / visual-editor:step-deleted.
//
// All form fields are built using safe DOM methods (no innerHTML with user data).
export default class extends Controller {
  static targets = ["modal", "title", "body"]

  connect() {
    this.editingStepId = null
    this.editingStepType = null

    this.boundOpen = (e) => this.open(e.detail.step)
    this.boundClose = () => this.close()

    this.element.addEventListener("visual-editor:open-modal", this.boundOpen)
    this.element.addEventListener("visual-editor:close-modal", this.boundClose)
  }

  disconnect() {
    this.element.removeEventListener("visual-editor:open-modal", this.boundOpen)
    this.element.removeEventListener("visual-editor:close-modal", this.boundClose)
  }

  open(step) {
    if (!step) return

    this.editingStepId = step.id
    this.editingStepType = step.type

    if (this.hasTitleTarget) {
      this.titleTarget.textContent = `Edit ${this.capitalize(step.type || 'Step')}`
    }

    if (this.hasBodyTarget) {
      this.bodyTarget.replaceChildren()
      this.buildStepFormDOM(step, this.bodyTarget)
    }

    if (this.hasModalTarget) {
      this.modalTarget.classList.remove("is-hidden")
    }
  }

  close() {
    if (this.hasModalTarget) {
      this.modalTarget.classList.add("is-hidden")
    }
    this.editingStepId = null
    this.editingStepType = null
  }

  save() {
    if (!this.editingStepId || !this.hasBodyTarget) return

    const form = this.bodyTarget
    const data = {}

    // Read common fields
    const titleInput = form.querySelector('[name="step-title"]')
    if (titleInput) data.title = titleInput.value

    const descInput = form.querySelector('[name="step-description"]')
    if (descInput) data.description = descInput.value

    // Read type-specific fields
    if (this.editingStepType) {
      switch (this.editingStepType) {
        case "question":
          this.readField(form, "step-question", data, "question")
          this.readField(form, "step-answer-type", data, "answer_type")
          this.readField(form, "step-variable-name", data, "variable_name")
          break
        case "action":
          this.readField(form, "step-action-type", data, "action_type")
          this.readField(form, "step-instructions", data, "instructions")
          this.readCheckboxField(form, "step-can-resolve", data, "can_resolve")
          break
        case "message":
          this.readField(form, "step-content", data, "content")
          this.readCheckboxField(form, "step-can-resolve", data, "can_resolve")
          break
        case "escalate":
          this.readField(form, "step-target-type", data, "target_type")
          this.readField(form, "step-target-value", data, "target_value")
          this.readField(form, "step-priority", data, "priority")
          this.readField(form, "step-notes", data, "notes")
          break
        case "resolve":
          this.readField(form, "step-resolution-type", data, "resolution_type")
          this.readField(form, "step-resolution-code", data, "resolution_code")
          break
        case "sub_flow":
          this.readField(form, "step-target-workflow-id", data, "target_workflow_id")
          break
      }
    }

    this.element.dispatchEvent(new CustomEvent("visual-editor:step-saved", {
      bubbles: false,
      detail: { stepId: this.editingStepId, data }
    }))

    this.close()
  }

  deleteStep() {
    if (!this.editingStepId) return

    const titleInput = this.hasBodyTarget
      ? this.bodyTarget.querySelector('[name="step-title"]')
      : null
    const title = titleInput ? titleInput.value : "this step"

    if (confirm(`Delete "${title}"?`)) {
      this.element.dispatchEvent(new CustomEvent("visual-editor:step-deleted", {
        bubbles: false,
        detail: { stepId: this.editingStepId }
      }))
      this.close()
    }
  }

  // --- Form Field Readers ---

  readField(form, name, data, key) {
    const el = form.querySelector(`[name="${name}"]`)
    if (el) data[key] = el.value
  }

  readCheckboxField(form, name, data, key) {
    const el = form.querySelector(`[name="${name}"]`)
    if (el) data[key] = el.checked
  }

  // --- Form Builders (safe DOM methods, no innerHTML with user data) ---

  buildStepFormDOM(step, container) {
    const wrapper = document.createElement("div")
    wrapper.className = "form-stack"

    wrapper.appendChild(this.createTextField("Title", "step-title", step.title || ""))
    wrapper.appendChild(this.createTextareaField("Description", "step-description", step.description || "", 2))

    switch (step.type) {
      case "question":
        wrapper.appendChild(this.createTextareaField("Question", "step-question", step.question || "", 2))
        wrapper.appendChild(this.createSelectField("Answer Type", "step-answer-type", step.answer_type || "yes_no",
          ["yes_no", "multiple_choice", "dropdown", "text", "number", "date", "file"].map(at => ({ value: at, label: at.replace(/_/g, " ") }))
        ))
        wrapper.appendChild(this.createTextField("Variable Name", "step-variable-name", step.variable_name || ""))
        break
      case "action":
        wrapper.appendChild(this.createSelectField("Action Type", "step-action-type", step.action_type || "Instruction",
          ["Instruction", "API Call", "Email", "Notification", "Custom"].map(at => ({ value: at, label: at }))
        ))
        wrapper.appendChild(this.createTextareaField("Instructions", "step-instructions", step.instructions || "", 3))
        wrapper.appendChild(this.createCheckboxField("This step may resolve the issue", "step-can-resolve", step.can_resolve))
        break
      case "message":
        wrapper.appendChild(this.createTextareaField("Message Content", "step-content", step.content || "", 4))
        wrapper.appendChild(this.createCheckboxField("This step may resolve the issue", "step-can-resolve", step.can_resolve))
        break
      case "escalate":
        wrapper.appendChild(this.createTextField("Target Type", "step-target-type", step.target_type || ""))
        wrapper.appendChild(this.createTextField("Target Value", "step-target-value", step.target_value || ""))
        wrapper.appendChild(this.createSelectField("Priority", "step-priority", step.priority || "normal",
          ["low", "normal", "high", "urgent"].map(p => ({ value: p, label: p.charAt(0).toUpperCase() + p.slice(1) }))
        ))
        wrapper.appendChild(this.createTextareaField("Notes", "step-notes", step.notes || "", 2))
        break
      case "resolve":
        wrapper.appendChild(this.createSelectField("Resolution Type", "step-resolution-type", step.resolution_type || "success",
          ["success", "failure", "partial", "cancelled"].map(rt => ({ value: rt, label: rt.charAt(0).toUpperCase() + rt.slice(1) }))
        ))
        wrapper.appendChild(this.createTextField("Resolution Code", "step-resolution-code", step.resolution_code || ""))
        break
      case "sub_flow":
        wrapper.appendChild(this.createTextField("Target Workflow ID", "step-target-workflow-id", step.target_workflow_id || ""))
        break
    }

    container.appendChild(wrapper)
  }

  createTextField(label, name, value) {
    const div = document.createElement("div")
    div.className = "form-group"
    const lbl = document.createElement("label")
    lbl.className = "form-label"
    lbl.textContent = label
    div.appendChild(lbl)

    const input = document.createElement("input")
    input.type = "text"
    input.name = name
    input.value = value
    input.className = "form-input"
    div.appendChild(input)
    return div
  }

  createTextareaField(label, name, value, rows) {
    const div = document.createElement("div")
    div.className = "form-group"
    const lbl = document.createElement("label")
    lbl.className = "form-label"
    lbl.textContent = label
    div.appendChild(lbl)

    const textarea = document.createElement("textarea")
    textarea.name = name
    textarea.rows = rows
    textarea.value = value
    textarea.textContent = value
    textarea.className = "form-textarea"
    div.appendChild(textarea)
    return div
  }

  createSelectField(label, name, selectedValue, options) {
    const div = document.createElement("div")
    div.className = "form-group"
    const lbl = document.createElement("label")
    lbl.className = "form-label"
    lbl.textContent = label
    div.appendChild(lbl)

    const select = document.createElement("select")
    select.name = name
    select.className = "form-select"

    options.forEach(opt => {
      const option = document.createElement("option")
      option.value = opt.value
      option.textContent = opt.label
      if (opt.value === selectedValue) option.selected = true
      select.appendChild(option)
    })

    div.appendChild(select)
    return div
  }

  createCheckboxField(label, name, checked) {
    const div = document.createElement("div")
    const lbl = document.createElement("label")
    lbl.className = "form-checkbox-label"

    const input = document.createElement("input")
    input.type = "checkbox"
    input.name = name
    input.checked = !!checked
    input.className = "form-checkbox"
    lbl.appendChild(input)

    const span = document.createElement("span")
    span.className = "form-checkbox-text"
    span.textContent = label
    lbl.appendChild(span)

    div.appendChild(lbl)
    return div
  }

  // --- Utilities ---

  capitalize(str) {
    if (!str) return ''
    return str.charAt(0).toUpperCase() + str.slice(1).replace(/_/g, ' ')
  }
}
