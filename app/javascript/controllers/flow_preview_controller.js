import { Controller } from "@hotwired/stimulus"
import { FlowchartRenderer } from "services/flowchart_renderer"

export default class extends Controller {
  static targets = ["canvas"]

  connect() {
    this.renderer = new FlowchartRenderer()

    // Delay initial render to ensure DOM is ready
    setTimeout(() => {
      this.render()
    }, 100)
    // Listen for updates from workflow builder
    this.setupUpdateListener()
  }

  disconnect() {
    // Clean up event listeners
    if (this.boundRender) {
      document.removeEventListener("workflow:updated", this.boundRender)
    }
    if (this.form) {
      if (this.boundFormInput) {
        this.form.removeEventListener("input", this.boundFormInput)
      }
      if (this.boundFormChange) {
        this.form.removeEventListener("change", this.boundFormChange)
      }
    }
    if (this.renderTimeout) {
      clearTimeout(this.renderTimeout)
    }
  }

  setupUpdateListener() {
    // Listen for custom events from workflow builder
    this.boundRender = () => this.render()
    document.addEventListener("workflow:updated", this.boundRender)

    // Also listen for form changes
    this.form = document.querySelector("form")
    if (this.form) {
      this.boundFormInput = () => {
        clearTimeout(this.renderTimeout)
        this.renderTimeout = setTimeout(() => this.render(), 300)
      }
      this.boundFormChange = () => {
        clearTimeout(this.renderTimeout)
        this.renderTimeout = setTimeout(() => this.render(), 300)
      }

      this.form.addEventListener("input", this.boundFormInput)
      this.form.addEventListener("change", this.boundFormChange)
    }
  }

  // Check if graph mode is enabled
  isGraphMode() {
    const graphModeCheckbox = document.querySelector("input[name*='graph_mode']")
    return graphModeCheckbox?.checked || false
  }

  // Parse steps from the form
  parseSteps() {
    const steps = []
    const isGraphMode = this.isGraphMode()

    // Find step items within the workflow builder container
    const workflowBuilder = document.querySelector("[data-controller*='workflow-builder']")
    const stepItems = workflowBuilder
      ? workflowBuilder.querySelectorAll(".step-item")
      : document.querySelectorAll(".step-item")

    stepItems.forEach((stepItem, index) => {
      const typeInput = stepItem.querySelector("input[name*='[type]']")
      const titleInput = stepItem.querySelector("input[name*='[title]']")
      const idInput = stepItem.querySelector("input[name*='[id]']")

      if (!typeInput || !titleInput) {
        return
      }

      const type = typeInput.value
      const title = titleInput.value.trim() || `Step ${index + 1}`
      const id = idInput?.value || `step-${index}`

      // Skip if no type
      if (!type) return

      const step = {
        id: id,
        type: type,
        title: title,
        index: index
      }

      // Parse graph mode transitions
      if (isGraphMode) {
        const transitionsInput = stepItem.querySelector("input[name*='transitions_json']")
        if (transitionsInput && transitionsInput.value) {
          try {
            step.transitions = JSON.parse(transitionsInput.value)
          } catch (e) {
            step.transitions = []
          }
        } else {
          step.transitions = []
        }
      }

      // Get type-specific fields
      if (type === "question") {
        const questionInput = stepItem.querySelector("input[name*='[question]']")
        step.question = questionInput ? questionInput.value : ""
      } else if (type === "action") {
        const instructionsInput = stepItem.querySelector("textarea[name*='[instructions]']")
        step.instructions = instructionsInput ? instructionsInput.value : ""
      } else if (type === "sub_flow") {
        const targetInput = stepItem.querySelector("input[name*='target_workflow_id']")
        step.target_workflow_id = targetInput ? targetInput.value : ""
      }

      steps.push(step)
    })

    return steps
  }

  // Render the flowchart
  render() {
    if (!this.hasCanvasTarget) return

    const steps = this.parseSteps()

    if (steps.length === 0) {
      this.canvasTarget.innerHTML = '<p class="text-gray-500 text-center py-8">Add steps to see the flow preview</p>'
      return
    }

    const html = this.renderer.render(steps)
    this.canvasTarget.innerHTML = html
  }
}
