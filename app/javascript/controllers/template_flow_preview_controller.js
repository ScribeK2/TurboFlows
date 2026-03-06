import { Controller } from "@hotwired/stimulus"
import { FlowchartRenderer } from "services/flowchart_renderer"

// Controller for rendering flow previews from template data
// Similar to flow_preview_controller but works with JSON data instead of form inputs
export default class extends Controller {
  static targets = ["canvas", "zoomLevel"]
  static values = {
    compact: Boolean
  }

  connect() {
    // Initialize zoom level
    this.zoomLevel = 1.0 // 100%
    this.canvasWidth = 0
    this.canvasHeight = 0

    // Create renderer with appropriate options
    this.renderer = new FlowchartRenderer({
      compact: this.compactValue,
      nodeWidth: this.compactValue ? 120 : 200,
      nodeHeight: this.compactValue ? 80 : 120,
      nodeMargin: this.compactValue ? 20 : 40
    })

    // Load steps from script tag
    this.loadStepsFromScript()

    // Listen for render-preview event (triggered when modal opens)
    this.boundRenderPreview = () => {
      setTimeout(() => this.render(), 50)
    }
    this.element.addEventListener('render-preview', this.boundRenderPreview)

    // Keyboard shortcuts for zoom (only when modal is visible)
    this.boundKeyDown = this.handleKeyDown.bind(this)
    document.addEventListener('keydown', this.boundKeyDown)

    this.setupPanGesture()

    // Delay initial render to ensure DOM is ready
    // For modals, we'll render when modal opens (via event)
    // For inline previews, render immediately
    if (!this.element.closest('[id^="template-preview-modal-"]')) {
      setTimeout(() => {
        this.render()
      }, 100)
    }
  }

  disconnect() {
    document.removeEventListener('keydown', this.boundKeyDown)
    if (this.boundRenderPreview) {
      this.element.removeEventListener('render-preview', this.boundRenderPreview)
    }
    this.teardownPanGesture()
  }

  setupPanGesture() {
    this.isPanning = false
    this.panStartX = 0
    this.panStartY = 0
    this.scrollStartX = 0
    this.scrollStartY = 0

    this.boundPanWheel = this.handlePanWheel.bind(this)
    this.boundPanMouseDown = this.handlePanMouseDown.bind(this)
    this.boundPanMouseMove = this.handlePanMouseMove.bind(this)
    this.boundPanMouseUp = this.handlePanMouseUp.bind(this)

    if (this.hasCanvasTarget) {
      this.canvasTarget.addEventListener("wheel", this.boundPanWheel, { passive: false })
      this.canvasTarget.addEventListener("mousedown", this.boundPanMouseDown)
      document.addEventListener("mousemove", this.boundPanMouseMove)
      document.addEventListener("mouseup", this.boundPanMouseUp)
    }
  }

  teardownPanGesture() {
    if (this.hasCanvasTarget) {
      this.canvasTarget.removeEventListener("wheel", this.boundPanWheel)
      this.canvasTarget.removeEventListener("mousedown", this.boundPanMouseDown)
    }
    document.removeEventListener("mousemove", this.boundPanMouseMove)
    document.removeEventListener("mouseup", this.boundPanMouseUp)
  }

  handlePanWheel(e) {
    if (e.ctrlKey || e.metaKey) {
      e.preventDefault()
      const delta = e.deltaY > 0 ? -0.1 : 0.1
      this.zoomLevel = Math.min(2.0, Math.max(0.25, this.zoomLevel + delta))
      this.applyZoom()
    }
  }

  handlePanMouseDown(e) {
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

  handlePanMouseMove(e) {
    if (!this.isPanning) return
    e.preventDefault()
    const dx = e.clientX - this.panStartX
    const dy = e.clientY - this.panStartY
    this.canvasTarget.scrollLeft = this.scrollStartX - dx
    this.canvasTarget.scrollTop = this.scrollStartY - dy
  }

  handlePanMouseUp() {
    if (this.isPanning) {
      this.isPanning = false
      if (this.hasCanvasTarget) {
        this.canvasTarget.style.cursor = ""
      }
    }
  }

  handleKeyDown(event) {
    // Only handle keyboard shortcuts when this controller's modal is visible
    const modal = this.element.closest('[id^="template-preview-modal-"]')
    if (!modal || modal.classList.contains('hidden')) return

    // Check for Ctrl/Cmd + Plus (zoom in)
    if ((event.ctrlKey || event.metaKey) && (event.key === '+' || event.key === '=')) {
      event.preventDefault()
      this.zoomIn()
    }

    // Check for Ctrl/Cmd + Minus (zoom out)
    if ((event.ctrlKey || event.metaKey) && event.key === '-') {
      event.preventDefault()
      this.zoomOut()
    }

    // Check for Ctrl/Cmd + 0 (fit to screen)
    if ((event.ctrlKey || event.metaKey) && event.key === '0') {
      event.preventDefault()
      this.fitToScreen()
    }
  }

  // Load steps from script tag (safer than HTML attributes for complex JSON)
  loadStepsFromScript() {
    const scriptTag = this.element.querySelector('script[type="application/json"]')
    if (scriptTag) {
      try {
        const stepsJson = scriptTag.textContent.trim()
        this.stepsData = JSON.parse(stepsJson)
      } catch (e) {
        console.error('Error parsing template steps JSON:', e)
        this.stepsData = []
      }
    } else {
      this.stepsData = []
    }
  }

  // Parse steps from the loaded data
  parseSteps() {
    const stepsData = this.stepsData || []

    return stepsData.map((step, index) => {
      return {
        id: step.id || step['id'] || '',
        type: step.type || step['type'] || '',
        title: step.title || step['title'] || `Step ${index + 1}`,
        index: index,
        transitions: step.transitions || step['transitions'] || undefined,
        condition: step.condition || step['condition'] || '',
        true_path: step.true_path || step['true_path'] || '',
        false_path: step.false_path || step['false_path'] || '',
        else_path: step.else_path || step['else_path'] || '',
        branches: step.branches || step['branches'] || []
      }
    }).filter(step => step.type) // Filter out steps without type
  }

  // Render the flowchart
  render() {
    if (!this.hasCanvasTarget) return

    const steps = this.parseSteps()

    if (steps.length === 0) {
      this.canvasTarget.innerHTML = '<p class="text-gray-500 text-center py-4 text-sm">No steps in template</p>'
      return
    }

    // Get container width - wait longer for modal to be fully visible
    requestAnimationFrame(() => {
      setTimeout(() => {
        const html = this.renderer.render(steps)
        this.canvasTarget.innerHTML = html

        // Store canvas dimensions for fit-to-screen calculation
        setTimeout(() => {
          const canvasContent = this.canvasTarget.querySelector('.relative')
          if (canvasContent) {
            this.canvasWidth = canvasContent.offsetWidth || canvasContent.scrollWidth
            this.canvasHeight = canvasContent.offsetHeight || canvasContent.scrollHeight

            // Apply current zoom level
            this.applyZoom()
          }
        }, 10)
      }, 50)
    })
  }

  // Zoom in
  zoomIn() {
    this.zoomLevel = Math.min(this.zoomLevel + 0.1, 2.0) // Max 200%
    this.applyZoom()
  }

  // Zoom out
  zoomOut() {
    this.zoomLevel = Math.max(this.zoomLevel - 0.1, 0.25) // Min 25%
    this.applyZoom()
  }

  // Fit to screen
  fitToScreen() {
    if (!this.hasCanvasTarget || this.canvasWidth === 0 || this.canvasHeight === 0) {
      const canvasContent = this.canvasTarget.querySelector('.relative')
      if (canvasContent) {
        this.canvasWidth = canvasContent.offsetWidth || canvasContent.scrollWidth
        this.canvasHeight = canvasContent.offsetHeight || canvasContent.scrollHeight
      }
    }

    if (this.canvasWidth === 0 || this.canvasHeight === 0) return

    const containerWidth = this.canvasTarget.offsetWidth - 40
    const containerHeight = this.canvasTarget.offsetHeight - 40

    const widthZoom = containerWidth / this.canvasWidth
    const heightZoom = containerHeight / this.canvasHeight

    this.zoomLevel = Math.min(widthZoom, heightZoom, 1.0) * 0.95
    this.applyZoom()
  }

  // Apply zoom transform to canvas content
  applyZoom() {
    if (!this.hasCanvasTarget) return

    const canvasContent = this.canvasTarget.querySelector('.relative')
    if (canvasContent) {
      if (!this.canvasWidth || !this.canvasHeight) {
        this.canvasWidth = canvasContent.offsetWidth || canvasContent.scrollWidth
        this.canvasHeight = canvasContent.offsetHeight || canvasContent.scrollHeight
      }

      canvasContent.style.transform = `scale(${this.zoomLevel})`
      canvasContent.style.transformOrigin = 'top left'

      if (this.hasZoomLevelTarget) {
        this.zoomLevelTarget.textContent = `${Math.round(this.zoomLevel * 100)}%`
      }
    }
  }
}
