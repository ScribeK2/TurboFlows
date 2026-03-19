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
    this.setupNodeClickListener()

    // Listen for step:selected events to highlight matching preview node
    this.boundStepSelected = (event) => {
      const stepId = event.detail?.stepId
      if (stepId) this.highlightNode(stepId)
    }
    document.addEventListener("step:selected", this.boundStepSelected)
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
    if (this.boundStepSelected) {
      document.removeEventListener("step:selected", this.boundStepSelected)
    }
  }

  setupNodeClickListener() {
    if (!this.hasCanvasTarget) return
    this.canvasTarget.addEventListener("click", (event) => {
      const node = event.target.closest(".workflow-node[data-step-id]")
      if (!node) return
      const stepId = node.dataset.stepId
      if (stepId) {
        document.dispatchEvent(new CustomEvent("flow-preview:node-clicked", {
          detail: { stepId }
        }))
      }
    })
  }

  highlightNode(stepId) {
    if (!this.hasCanvasTarget) return
    const node = this.canvasTarget.querySelector(`.workflow-node[data-step-id='${CSS.escape(stepId)}']`)
    if (!node) return
    node.classList.add("is-sync-highlighted")
    node.scrollIntoView({ behavior: "smooth", block: "center" })
    setTimeout(() => node.classList.remove("is-sync-highlighted"), 2000)
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
    const inner = this.canvasTarget.querySelector(".flowchart-canvas")
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
    const inner = this.canvasTarget.querySelector(".flowchart-canvas")
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
    // When visual editor is active, read steps from its service data
    // instead of the hidden list editor DOM
    const visualEditor = document.getElementById("visual-editor-container")
    if (visualEditor && !visualEditor.classList.contains("is-hidden")) {
      return this.parseStepsFromVisualEditor(visualEditor)
    }

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

  parseStepsFromVisualEditor(container) {
    // Read step data from the visual editor's hidden JSON input
    const stepsInput = container.querySelector("[data-visual-editor-target='stepsInput']")
    if (!stepsInput || !stepsInput.value) {
      // Fall back to the initial stepsData script tag
      const dataScript = container.querySelector("[data-visual-editor-target='stepsData']")
      if (dataScript) {
        try {
          const rawSteps = JSON.parse(dataScript.textContent)
          return rawSteps.map((s, i) => ({
            id: s.id,
            type: s.type,
            title: s.title || `Step ${i + 1}`,
            index: i,
            transitions: s.transitions || [],
            isStartNode: s.isStartNode
          }))
        } catch (e) {
          return []
        }
      }
      return []
    }

    try {
      const rawSteps = JSON.parse(stepsInput.value)
      return rawSteps.map((s, i) => ({
        id: s.id,
        type: s.type,
        title: s.title || `Step ${i + 1}`,
        index: i,
        transitions: s.transitions || [],
        isStartNode: s.isStartNode
      }))
    } catch (e) {
      return []
    }
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
    // Renderer output is built from escapeHtml-protected internal methods
    this.canvasTarget.innerHTML = html
    this.applyZoom()

    // Auto-fit when content overflows (e.g. in split-pane mode)
    if (this.canvasTarget.scrollWidth > this.canvasTarget.clientWidth + 10) {
      this.fitToScreen()
    }
  }
}
