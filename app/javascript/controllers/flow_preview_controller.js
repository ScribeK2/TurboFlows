import { Controller } from "@hotwired/stimulus"
import { FlowchartRenderer } from "services/flowchart_renderer"

export default class extends Controller {
  static targets = ["canvas", "zoomLevel"]

  connect() {
    this.renderer = new FlowchartRenderer()
    this.zoomLevel = 1.0

    // Delay initial render to ensure DOM is ready
    setTimeout(() => {
      this.render()
    }, 100)
    // Listen for updates from workflow builder
    this.setupUpdateListener()
    this.setupPanZoom()
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
    this.teardownPanZoom()
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

  setupPanZoom() {
    this.isPanning = false
    this.panStartX = 0
    this.panStartY = 0
    this.scrollStartX = 0
    this.scrollStartY = 0

    this.boundHandleWheel = this.handleWheel.bind(this)
    this.boundHandleMouseDown = this.handleMouseDown.bind(this)
    this.boundHandleMouseMove = this.handleMouseMove.bind(this)
    this.boundHandleMouseUp = this.handleMouseUp.bind(this)

    if (this.hasCanvasTarget) {
      this.canvasTarget.addEventListener("wheel", this.boundHandleWheel, { passive: false })
      this.canvasTarget.addEventListener("mousedown", this.boundHandleMouseDown)
      document.addEventListener("mousemove", this.boundHandleMouseMove)
      document.addEventListener("mouseup", this.boundHandleMouseUp)
    }
  }

  teardownPanZoom() {
    if (this.hasCanvasTarget) {
      this.canvasTarget.removeEventListener("wheel", this.boundHandleWheel)
      this.canvasTarget.removeEventListener("mousedown", this.boundHandleMouseDown)
    }
    document.removeEventListener("mousemove", this.boundHandleMouseMove)
    document.removeEventListener("mouseup", this.boundHandleMouseUp)
  }

  handleWheel(e) {
    if (e.ctrlKey || e.metaKey) {
      e.preventDefault()
      const delta = e.deltaY > 0 ? -0.1 : 0.1
      this.zoomLevel = Math.min(2.0, Math.max(0.25, this.zoomLevel + delta))
      this.applyZoom()
    }
  }

  handleMouseDown(e) {
    if (e.altKey) {
      e.preventDefault()
      this.isPanning = true
      this.panStartX = e.clientX
      this.panStartY = e.clientY
      this.scrollStartX = this.canvasTarget.scrollLeft
      this.scrollStartY = this.canvasTarget.scrollTop
      this.canvasTarget.style.cursor = "grabbing"
    }
  }

  handleMouseMove(e) {
    if (!this.isPanning) return
    e.preventDefault()
    const dx = e.clientX - this.panStartX
    const dy = e.clientY - this.panStartY
    this.canvasTarget.scrollLeft = this.scrollStartX - dx
    this.canvasTarget.scrollTop = this.scrollStartY - dy
  }

  handleMouseUp() {
    if (this.isPanning) {
      this.isPanning = false
      if (this.hasCanvasTarget) {
        this.canvasTarget.style.cursor = ""
      }
    }
  }

  zoomIn() {
    this.zoomLevel = Math.min(2.0, this.zoomLevel + 0.1)
    this.applyZoom()
  }

  zoomOut() {
    this.zoomLevel = Math.max(0.25, this.zoomLevel - 0.1)
    this.applyZoom()
  }

  fitToScreen() {
    if (!this.hasCanvasTarget) return
    const inner = this.canvasTarget.querySelector(".relative")
    if (!inner) return

    const containerWidth = this.canvasTarget.clientWidth
    const containerHeight = this.canvasTarget.clientHeight
    const contentWidth = inner.scrollWidth
    const contentHeight = inner.scrollHeight

    if (contentWidth === 0 || contentHeight === 0) return

    const scaleX = containerWidth / contentWidth
    const scaleY = containerHeight / contentHeight
    this.zoomLevel = Math.min(scaleX, scaleY, 1.0) * 0.9
    this.zoomLevel = Math.max(0.25, Math.min(2.0, this.zoomLevel))
    this.applyZoom()
  }

  applyZoom() {
    if (!this.hasCanvasTarget) return
    const inner = this.canvasTarget.querySelector(".relative")
    if (inner) {
      inner.style.transform = `scale(${this.zoomLevel})`
      inner.style.transformOrigin = "top left"
    }
    if (this.hasZoomLevelTarget) {
      this.zoomLevelTarget.textContent = `${Math.round(this.zoomLevel * 100)}%`
    }
  }

  // Parse steps from the form
  parseSteps() {
    const steps = []

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

      // Always parse transitions (all workflows use graph mode)
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
  // Note: innerHTML is safe here because FlowchartRenderer.escapeHtml() sanitizes
  // all user-provided text before insertion via document.createElement + textContent
  render() {
    if (!this.hasCanvasTarget) return

    const steps = this.parseSteps()

    if (steps.length === 0) {
      this.canvasTarget.innerHTML = '<p class="empty-state__text">Add steps to see the flow preview</p>'
      return
    }

    const html = this.renderer.render(steps)
    this.canvasTarget.innerHTML = html
    this.applyZoom()
  }
}
