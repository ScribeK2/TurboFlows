import { Controller } from "@hotwired/stimulus"
import { buildConditionPresets } from "services/condition_presets"

// Handles connection drawing, condition popover, and palette drag-drop
// for the visual editor.
//
// Listens for:
//   - visual-editor:start-connection (from parent, on output port mousedown)
//   - visual-editor:cancel-connection (from parent, on Escape key)
//   - visual-editor:hide-popover (from parent, on Escape key)
//   - visual-editor:rendered (to get zoom level for coordinate math)
//
// Dispatches:
//   - visual-editor:add-transition (parent calls service.addTransition)
//   - visual-editor:add-step (parent calls service.addStep + open modal)
export default class extends Controller {
  static targets = ["canvas", "tempSvg", "conditionPopover", "conditionOptions"]

  // Step type colors — matches FlowchartRenderer.getStepColor()
  static STEP_COLORS = {
    question: "#6366f1",
    action: "#10b981",
    sub_flow: "#8b5cf6",
    message: "#06b6d4",
    escalate: "#f97316",
    resolve: "#22c55e"
  }

  connect() {
    this.isConnecting = false
    this.connectionFromId = null
    this.connectionStartX = 0
    this.connectionStartY = 0
    this.zoomLevel = 1.0

    this.boundStartConnection = (e) => this.startConnection(e.detail.stepId, e.detail.event)
    this.boundCancelConnection = () => this.cancelConnection()
    this.boundHidePopover = () => this.hideConditionPopover()
    this.boundUpdateZoom = () => this.readZoomLevel()

    this.element.addEventListener("visual-editor:start-connection", this.boundStartConnection)
    this.element.addEventListener("visual-editor:cancel-connection", this.boundCancelConnection)
    this.element.addEventListener("visual-editor:hide-popover", this.boundHidePopover)
    this.element.addEventListener("visual-editor:rendered", this.boundUpdateZoom)
  }

  disconnect() {
    this.element.removeEventListener("visual-editor:start-connection", this.boundStartConnection)
    this.element.removeEventListener("visual-editor:cancel-connection", this.boundCancelConnection)
    this.element.removeEventListener("visual-editor:hide-popover", this.boundHidePopover)
    this.element.removeEventListener("visual-editor:rendered", this.boundUpdateZoom)
    this.element.dataset.connecting = "false"
  }

  // Read current zoom level from canvas-zoom controller's target
  readZoomLevel() {
    const zoomEl = this.element.querySelector("[data-canvas-zoom-target='zoomLevel']")
    if (zoomEl) {
      this.zoomLevel = parseInt(zoomEl.textContent, 10) / 100 || 1.0
    }
  }

  // --- Connection Drawing ---

  startConnection(fromStepId, e) {
    this.isConnecting = true
    this.connectionFromId = fromStepId
    this.element.dataset.connecting = "true"

    const canvasRect = this.canvasTarget.getBoundingClientRect()
    this.connectionStartX = (e.clientX - canvasRect.left + this.canvasTarget.scrollLeft) / this.zoomLevel
    this.connectionStartY = (e.clientY - canvasRect.top + this.canvasTarget.scrollTop) / this.zoomLevel

    // Highlight input ports on other nodes
    const canvasContent = this.element.querySelector("[data-visual-editor-target='canvasContent']")
    if (canvasContent) {
      canvasContent.querySelectorAll(".input-port").forEach(port => {
        if (port.dataset.stepId !== fromStepId) {
          port.classList.add("is-connection-target")
        }
      })
    }
  }

  handleCanvasMouseMove(e) {
    if (!this.isConnecting) return
    this.updateConnectionLine(e)
  }

  handleCanvasMouseUp(e) {
    if (!this.isConnecting) return
    this.finishConnection(e)
  }

  updateConnectionLine(e) {
    if (!this.hasTempSvgTarget) return
    const canvasRect = this.canvasTarget.getBoundingClientRect()
    const endX = (e.clientX - canvasRect.left + this.canvasTarget.scrollLeft) / this.zoomLevel
    const endY = (e.clientY - canvasRect.top + this.canvasTarget.scrollTop) / this.zoomLevel

    // Check if hovering over a valid target for color feedback
    const target = document.elementFromPoint(e.clientX, e.clientY)
    const inputPort = target?.closest(".input-port")
    const nodeEl = target?.closest(".workflow-node")
    const overValidTarget = inputPort
      ? inputPort.dataset.stepId !== this.connectionFromId
      : (nodeEl ? nodeEl.dataset.stepId !== this.connectionFromId : false)
    const strokeColor = overValidTarget ? "#22c55e" : "#ef4444"

    const line = document.createElementNS("http://www.w3.org/2000/svg", "line")
    line.setAttribute("x1", this.connectionStartX)
    line.setAttribute("y1", this.connectionStartY)
    line.setAttribute("x2", endX)
    line.setAttribute("y2", endY)
    line.setAttribute("stroke", strokeColor)
    line.setAttribute("stroke-width", "2")
    line.setAttribute("stroke-dasharray", "6,3")
    this.tempSvgTarget.replaceChildren(line)
  }

  finishConnection(e) {
    this.isConnecting = false
    this.element.dataset.connecting = "false"

    if (this.hasTempSvgTarget) this.tempSvgTarget.replaceChildren()

    // Reset port highlights
    const canvasContent = this.element.querySelector("[data-visual-editor-target='canvasContent']")
    if (canvasContent) {
      canvasContent.querySelectorAll(".input-port").forEach(port => {
        port.classList.remove("is-connection-target")
      })
    }

    // Find target node under cursor
    const target = document.elementFromPoint(e.clientX, e.clientY)
    if (!target) return

    const inputPort = target.closest(".input-port")
    const nodeEl = target.closest(".workflow-node")
    const toStepId = inputPort ? inputPort.dataset.stepId : (nodeEl ? nodeEl.dataset.stepId : null)

    if (!toStepId || toStepId === this.connectionFromId) {
      this.connectionFromId = null
      return
    }

    // Check source step type for smart presets — read from parent's service
    const visualEditorEl = this.element
    const veController = this.application.getControllerForElementAndIdentifier(visualEditorEl, "visual-editor")
    const sourceStep = veController ? veController.findStep(this.connectionFromId) : null

    if (sourceStep && sourceStep.type === "question") {
      this.showConditionPopover(e, this.connectionFromId, toStepId, sourceStep)
    } else {
      this.element.dispatchEvent(new CustomEvent("visual-editor:add-transition", {
        bubbles: false,
        detail: { fromId: this.connectionFromId, toId: toStepId, condition: "", label: "" }
      }))
    }

    this.connectionFromId = null
  }

  cancelConnection() {
    this.isConnecting = false
    this.connectionFromId = null
    this.element.dataset.connecting = "false"
    if (this.hasTempSvgTarget) this.tempSvgTarget.replaceChildren()

    const canvasContent = this.element.querySelector("[data-visual-editor-target='canvasContent']")
    if (canvasContent) {
      canvasContent.querySelectorAll(".input-port").forEach(port => {
        port.classList.remove("is-connection-target")
      })
    }
  }

  // --- Condition Popover ---

  showConditionPopover(e, fromId, toId, sourceStep) {
    if (!this.hasConditionPopoverTarget || !this.hasConditionOptionsTarget) return

    const presets = buildConditionPresets(sourceStep)

    const container = this.conditionOptionsTarget
    container.replaceChildren()

    presets.forEach(preset => {
      const btn = document.createElement("button")
      btn.type = "button"
      btn.className = "condition-preset-btn"
      btn.dataset.action = "click->ve-connection#applyConditionPreset"
      btn.dataset.fromId = fromId
      btn.dataset.toId = toId
      btn.dataset.condition = preset.condition
      btn.dataset.label = preset.label
      btn.textContent = preset.displayLabel
      container.appendChild(btn)
    })

    this.conditionPopoverTarget.style.left = `${e.clientX}px`
    this.conditionPopoverTarget.style.top = `${e.clientY}px`
    this.conditionPopoverTarget.classList.remove("is-hidden")
  }

  hideConditionPopover() {
    if (this.hasConditionPopoverTarget) {
      this.conditionPopoverTarget.classList.add("is-hidden")
    }
  }

  applyConditionPreset(e) {
    const { fromId, toId, condition, label } = e.currentTarget.dataset
    this.element.dispatchEvent(new CustomEvent("visual-editor:add-transition", {
      bubbles: false,
      detail: { fromId, toId, condition, label }
    }))
    this.hideConditionPopover()
  }

  // --- Drag from Palette ---

  handlePaletteDragStart(e) {
    const stepType = e.currentTarget.dataset.stepType
    if (!stepType) return
    e.dataTransfer.setData("text/plain", stepType)
    e.dataTransfer.effectAllowed = "copy"

    const ghost = document.createElement("div")
    ghost.textContent = this.capitalize(stepType.replace("_", " "))
    ghost.style.cssText = "position:absolute;top:-9999px;left:-9999px;padding:6px 14px;border-radius:8px;font-size:13px;font-weight:600;color:#fff;white-space:nowrap;pointer-events:none;box-shadow:0 4px 12px rgba(0,0,0,0.15);"
    ghost.style.backgroundColor = this.constructor.STEP_COLORS[stepType] || "#6b7280"
    document.body.appendChild(ghost)
    e.dataTransfer.setDragImage(ghost, ghost.offsetWidth / 2, ghost.offsetHeight / 2)

    requestAnimationFrame(() => document.body.removeChild(ghost))
  }

  handleCanvasDragOver(e) {
    e.preventDefault()
    e.dataTransfer.dropEffect = "copy"
  }

  handleCanvasDrop(e) {
    e.preventDefault()
    const stepType = e.dataTransfer.getData("text/plain")
    if (!stepType) return

    this.element.dispatchEvent(new CustomEvent("visual-editor:add-step", {
      bubbles: false,
      detail: { type: stepType }
    }))
  }

  // --- Utilities ---

  capitalize(str) {
    if (!str) return ''
    return str.charAt(0).toUpperCase() + str.slice(1).replace(/_/g, ' ')
  }
}
