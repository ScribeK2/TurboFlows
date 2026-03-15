import { Controller } from "@hotwired/stimulus"
import { FlowchartRenderer } from "services/flowchart_renderer"

// Wizard-specific flow preview controller for step3
// Reads steps from workflow data instead of form inputs
export default class extends Controller {
  static targets = ["canvas", "zoomLevel"]
  static values = {
    workflowId: Number,
    stepsData: Array
  }

  connect() {
    this.renderer = new FlowchartRenderer({
      darkMode: true,
      clickable: true,
      arrowIdPrefix: 'wizard-'
    })
    this.zoomLevel = 1.0

    // Load steps from script tag (safer than HTML attributes for complex JSON)
    this.loadStepsFromScript()
    // Delay initial render to ensure DOM is ready
    setTimeout(() => {
      this.render()
      // Auto fit after initial render
      setTimeout(() => this.fitToScreen(), 50)
    }, 100)
    this.setupPanZoom()
  }

  disconnect() {
    this.teardownPanZoom()
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

  refresh() {
    this.loadStepsFromScript()
    this.render()
  }

  // Load steps from script tag (safer than HTML attributes for complex JSON)
  loadStepsFromScript() {
    const scriptTag = this.element.querySelector('script[type="application/json"]')
    if (scriptTag) {
      try {
        const stepsJson = scriptTag.textContent.trim()
        this.stepsDataValue = JSON.parse(stepsJson)
      } catch (e) {
        console.error('Error parsing workflow steps JSON:', e)
        this.stepsDataValue = []
      }
    } else {
      this.stepsDataValue = []
    }
  }

  // Get steps from the workflow data value
  getSteps() {
    if (!this.hasStepsDataValue || !this.stepsDataValue || this.stepsDataValue.length === 0) {
      return []
    }

    // Ensure steps have index property
    return this.stepsDataValue.map((step, index) => ({
      ...step,
      index: index
    }))
  }

  // Render uses FlowchartRenderer which sanitizes all user text via escapeHtml()
  // (document.createElement + textContent pattern) before DOM insertion
  render() {
    const steps = this.getSteps()
    if (!steps || steps.length === 0) {
      if (this.hasCanvasTarget) {
        this.canvasTarget.textContent = ''
        const msg = document.createElement('p')
        msg.className = 'flowchart-empty'
        msg.textContent = 'No steps to preview. Add steps to see the flowchart.'
        this.canvasTarget.appendChild(msg)
      }
      return
    }

    // FlowchartRenderer.render() returns pre-sanitized HTML (all user content
    // passes through escapeHtml which uses textContent assignment to sanitize)
    const html = this.renderer.render(steps)
    if (this.hasCanvasTarget) {
      this.canvasTarget.innerHTML = html  // safe: renderer escapes all user input
      this.applyZoom()
    }
  }

  editStep(event) {
    event.preventDefault()
    const stepIndex = parseInt(event.currentTarget.dataset.stepIndex)
    if (isNaN(stepIndex)) return

    const steps = this.getSteps()
    const step = steps[stepIndex]
    if (!step) return

    // Dispatch event to open step modal with the step data
    const editEvent = new CustomEvent("wizard-flow-preview:edit-step", {
      detail: { stepIndex, step, workflowId: this.workflowIdValue },
      bubbles: true
    })
    document.dispatchEvent(editEvent)

    // Also navigate to step2 as fallback
    const workflowId = this.workflowIdValue
    if (workflowId) {
      Turbo.visit(`/workflows/${workflowId}/step2#step-${stepIndex}`)
    }
  }
}
