import { Controller } from "@hotwired/stimulus"

// Handles zoom/pan behavior for the visual editor canvas.
// Self-contained — no service or renderer access needed.
//
// Listens for:
//   - visual-editor:rendered (re-applies zoom after render)
// Dispatches:
//   - visual-editor:auto-arrange (parent re-renders with dagre layout)
export default class extends Controller {
  static targets = ["canvas", "canvasContent", "zoomLevel"]

  connect() {
    this.zoomLevelNum = 1.0
    this.isPanning = false
    this.panStartX = 0
    this.panStartY = 0
    this.panScrollX = 0
    this.panScrollY = 0

    // Re-apply zoom after each render cycle
    this.boundApplyZoom = () => this.applyZoom()
    this.element.addEventListener("visual-editor:rendered", this.boundApplyZoom)
  }

  disconnect() {
    this.element.removeEventListener("visual-editor:rendered", this.boundApplyZoom)
  }

  // --- Zoom ---

  zoomIn() {
    this.zoomLevelNum = Math.min(2.0, this.zoomLevelNum + 0.1)
    this.applyZoom()
  }

  zoomOut() {
    this.zoomLevelNum = Math.max(0.25, this.zoomLevelNum - 0.1)
    this.applyZoom()
  }

  fitToScreen() {
    if (!this.hasCanvasTarget || !this.hasCanvasContentTarget) return
    const container = this.canvasTarget
    const content = this.canvasContentTarget.firstElementChild
    if (!content) return

    const containerW = container.clientWidth
    const containerH = container.clientHeight
    const contentW = content.scrollWidth || containerW
    const contentH = content.scrollHeight || containerH

    const scaleX = containerW / contentW
    const scaleY = containerH / contentH
    this.zoomLevelNum = Math.max(0.25, Math.min(2.0, Math.min(scaleX, scaleY) * 0.9))
    this.applyZoom()
  }

  applyZoom() {
    if (this.hasCanvasContentTarget) {
      this.canvasContentTarget.style.transform = `scale(${this.zoomLevelNum})`
      this.canvasContentTarget.style.transformOrigin = "top left"
    }
    if (this.hasZoomLevelTarget) {
      this.zoomLevelTarget.textContent = `${Math.round(this.zoomLevelNum * 100)}%`
    }
  }

  autoArrange() {
    this.element.dispatchEvent(new CustomEvent("visual-editor:auto-arrange", { bubbles: true }))
  }

  handleCanvasWheel(e) {
    if (!e.ctrlKey && !e.metaKey) return
    e.preventDefault()
    const delta = e.deltaY > 0 ? -0.05 : 0.05
    this.zoomLevelNum = Math.max(0.25, Math.min(2.0, this.zoomLevelNum + delta))
    this.applyZoom()
  }

  // --- Pan ---

  handleCanvasMouseDown(e) {
    if (e.altKey || e.button === 1) {
      e.preventDefault()
      this.isPanning = true
      this.panStartX = e.clientX
      this.panStartY = e.clientY
      this.panScrollX = this.canvasTarget.scrollLeft
      this.panScrollY = this.canvasTarget.scrollTop
      this.canvasTarget.style.cursor = "grabbing"
    }
  }

  handleCanvasMouseMove(e) {
    if (!this.isPanning) return
    const dx = e.clientX - this.panStartX
    const dy = e.clientY - this.panStartY
    this.canvasTarget.scrollLeft = this.panScrollX - dx
    this.canvasTarget.scrollTop = this.panScrollY - dy
  }

  handleCanvasMouseUp() {
    if (this.isPanning) {
      this.isPanning = false
      this.canvasTarget.style.cursor = ""
    }
  }

  // Expose panning state for parent controller's mouse routing
  get panning() {
    return this.isPanning
  }
}
