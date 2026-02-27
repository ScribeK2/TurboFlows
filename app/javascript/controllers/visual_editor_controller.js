import { Controller } from "@hotwired/stimulus"
import { FlowchartRenderer } from "services/flowchart_renderer"
import { VisualEditorService } from "services/visual_editor_service"

// Main orchestrator for the visual workflow editor.
// Wires together FlowchartRenderer (interactive mode), VisualEditorService,
// and handles canvas interactions: drag-drop, connections, zoom/pan, modals.
//
// XSS Safety: All user-provided content is escaped via escapeAttr() for attribute
// contexts and the renderer's escapeHtml() for HTML contexts. The renderer output
// (used in canvasContent) is built from escapeHtml-protected internal methods.
// Modal form fields use escaped values in attributes only. Condition popover
// buttons use escapeAttr() for all data attributes and display text.
export default class extends Controller {
  static targets = [
    "root", "canvas", "canvasContent", "emptyState", "stepsData",
    "stepsInput", "startNodeInput", "stepCount", "zoomLevel",
    "tempSvg", "conditionPopover", "conditionOptions", "palette",
    "stepModal", "modalTitle", "modalBody"
  ]

  static values = {
    workflowId: Number,
    mode: { type: String, default: "visual" }
  }

  connect() {
    this.renderer = new FlowchartRenderer({
      interactive: true,
      arrowIdPrefix: 'visual-',
      nodeWidth: 200,
      nodeHeight: 120
    })

    this.zoomLevelNum = 1.0
    this.isPanning = false
    this.isConnecting = false
    this.selectedStepId = null
    this.editingStepId = null
    this.connectionFromId = null
    this.connectionStartX = 0
    this.connectionStartY = 0
    this.panStartX = 0
    this.panStartY = 0
    this.panScrollX = 0
    this.panScrollY = 0

    // Parse steps from embedded JSON
    let steps = []
    if (this.hasStepsDataTarget) {
      try {
        steps = JSON.parse(this.stepsDataTarget.textContent) || []
      } catch (e) {
        console.warn("[VisualEditor] Failed to parse steps data:", e)
      }
    }

    // Detect start node from hidden input
    const startNodeUuid = this.hasStartNodeInputTarget
      ? this.startNodeInputTarget.value
      : undefined

    this.service = new VisualEditorService(steps, {
      startNodeUuid,
      onChange: () => this.handleServiceChange()
    })

    // Warn on unload if dirty
    this.boundBeforeUnload = (e) => {
      if (this.service.dirty) {
        e.preventDefault()
        e.returnValue = ""
      }
    }
    window.addEventListener("beforeunload", this.boundBeforeUnload)

    // Sync hidden inputs before form submission and clear dirty flag
    // so the beforeunload warning doesn't fire during a legitimate save
    this.boundFormSubmit = () => {
      this.syncHiddenInputs()
      this.service.dirty = false
    }
    const form = this.element.closest("form")
    if (form) {
      form.addEventListener("submit", this.boundFormSubmit)
    }

    this.render()
  }

  disconnect() {
    window.removeEventListener("beforeunload", this.boundBeforeUnload)
    const form = this.element.closest("form")
    if (form) {
      form.removeEventListener("submit", this.boundFormSubmit)
    }
  }

  // --- Rendering ---
  // Note: canvasContent receives output from FlowchartRenderer.render() which
  // internally uses escapeHtml() on all user-provided text (step titles, types,
  // labels). This is the same trusted rendering path used by the existing
  // flow_preview_controller, template_flow_preview_controller, etc.

  render() {
    const steps = this.service.stepsForRenderer()

    if (steps.length === 0) {
      if (this.hasEmptyStateTarget) this.emptyStateTarget.classList.remove("hidden")
      if (this.hasCanvasContentTarget) this.canvasContentTarget.innerHTML = ""
      this.updateStepCount(0)
      return
    }

    if (this.hasEmptyStateTarget) this.emptyStateTarget.classList.add("hidden")

    // Renderer output is built from escapeHtml-protected internal methods
    const html = this.renderer.render(steps)
    if (this.hasCanvasContentTarget) {
      this.canvasContentTarget.innerHTML = html
    }

    this.updateStepCount(steps.length)
    this.highlightOrphans()
    this.highlightSelected()
    this.applyZoom()
    this.attachNodeEventListeners()
  }

  handleServiceChange() {
    this.render()
    this.syncHiddenInputs()
  }

  updateStepCount(count) {
    if (this.hasStepCountTarget) {
      this.stepCountTarget.textContent = `${count} step${count !== 1 ? 's' : ''}`
    }
  }

  syncHiddenInputs() {
    if (this.hasStepsInputTarget) {
      this.stepsInputTarget.value = this.service.toJSON()
    }
    if (this.hasStartNodeInputTarget) {
      this.startNodeInputTarget.value = this.service.startNodeUuid || ""
    }
  }

  // --- Node Event Listeners ---

  attachNodeEventListeners() {
    if (!this.hasCanvasContentTarget) return

    const nodes = this.canvasContentTarget.querySelectorAll(".workflow-node")
    nodes.forEach(node => {
      const stepId = node.dataset.stepId
      if (!stepId) return

      node.addEventListener("click", (e) => {
        // Don't select if clicking a port
        if (e.target.closest(".output-port") || e.target.closest(".input-port")) return
        e.stopPropagation()
        this.selectNode(stepId)
      })

      node.addEventListener("dblclick", (e) => {
        e.stopPropagation()
        this.openStepModal(stepId)
      })

      // Output port: start connection
      const outputPort = node.querySelector(".output-port")
      if (outputPort) {
        outputPort.addEventListener("mousedown", (e) => {
          e.stopPropagation()
          e.preventDefault()
          this.startConnection(stepId, e)
        })
      }
    })

    // Edge group event listeners (hover to show delete, click to remove)
    const edgeGroups = this.canvasContentTarget.querySelectorAll(".edge-group")
    edgeGroups.forEach(group => {
      const pathEl = group.querySelector("path")
      const deleteBtn = group.querySelector(".edge-delete-btn")

      group.addEventListener("mouseenter", () => {
        if (pathEl) {
          pathEl.setAttribute("stroke-width", "4")
          pathEl.style.filter = "drop-shadow(0 0 3px rgba(0,0,0,0.3))"
        }
        if (deleteBtn) deleteBtn.style.display = ""
      })

      group.addEventListener("mouseleave", () => {
        if (pathEl) {
          pathEl.setAttribute("stroke-width", "2")
          pathEl.style.filter = ""
        }
        if (deleteBtn) deleteBtn.style.display = "none"
      })

      if (deleteBtn) {
        deleteBtn.addEventListener("click", (e) => {
          e.stopPropagation()
          const fromId = deleteBtn.dataset.fromId
          const connIndex = parseInt(deleteBtn.dataset.connIndex, 10)
          if (fromId && !isNaN(connIndex)) {
            this.service.removeTransition(fromId, connIndex)
          }
        })
      }
    })
  }

  // --- Selection ---

  selectNode(stepId) {
    this.selectedStepId = stepId
    this.highlightSelected()
  }

  deselectAll() {
    this.selectedStepId = null
    this.highlightSelected()
  }

  highlightSelected() {
    if (!this.hasCanvasContentTarget) return
    this.canvasContentTarget.querySelectorAll(".workflow-node").forEach(node => {
      const card = node.querySelector(":scope > div")
      if (!card) return
      if (node.dataset.stepId === this.selectedStepId) {
        card.classList.add("ring-2", "ring-blue-500", "ring-offset-2")
      } else {
        card.classList.remove("ring-2", "ring-blue-500", "ring-offset-2")
      }
    })
  }

  highlightOrphans() {
    if (!this.hasCanvasContentTarget) return
    const orphanIds = this.service.getOrphanStepIds()
    this.canvasContentTarget.querySelectorAll(".workflow-node").forEach(node => {
      const card = node.querySelector(":scope > div")
      if (!card) return
      if (orphanIds.includes(node.dataset.stepId)) {
        card.classList.add("ring-2", "ring-amber-400", "ring-offset-1")
      } else {
        card.classList.remove("ring-2", "ring-amber-400", "ring-offset-1")
      }
    })
  }

  // --- Zoom / Pan ---

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
    // Re-render triggers dagre re-layout
    this.render()
  }

  handleCanvasWheel(e) {
    if (!e.ctrlKey && !e.metaKey) return
    e.preventDefault()
    const delta = e.deltaY > 0 ? -0.05 : 0.05
    this.zoomLevelNum = Math.max(0.25, Math.min(2.0, this.zoomLevelNum + delta))
    this.applyZoom()
  }

  handleCanvasMouseDown(e) {
    // Alt+click or middle-click starts pan
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
    if (this.isPanning) {
      const dx = e.clientX - this.panStartX
      const dy = e.clientY - this.panStartY
      this.canvasTarget.scrollLeft = this.panScrollX - dx
      this.canvasTarget.scrollTop = this.panScrollY - dy
      return
    }

    if (this.isConnecting) {
      this.updateConnectionLine(e)
    }
  }

  handleCanvasMouseUp(e) {
    if (this.isPanning) {
      this.isPanning = false
      this.canvasTarget.style.cursor = ""
      return
    }

    if (this.isConnecting) {
      this.finishConnection(e)
    }
  }

  handleCanvasClick(e) {
    // Click on empty canvas space deselects
    if (e.target === this.canvasTarget || e.target === this.canvasContentTarget) {
      this.deselectAll()
    }
  }

  handleKeyDown(e) {
    if (e.key === "Escape") {
      if (this.isConnecting) {
        this.cancelConnection()
      } else if (this.hasStepModalTarget && !this.stepModalTarget.classList.contains("hidden")) {
        this.closeModal()
      } else {
        this.hideConditionPopover()
      }
      return
    }

    if ((e.key === "Delete" || e.key === "Backspace") && this.selectedStepId) {
      // Don't delete if focus is in an input
      if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA" || e.target.tagName === "SELECT") return
      e.preventDefault()
      const step = this.service.findStep(this.selectedStepId)
      const title = step ? step.title : "this step"
      if (confirm(`Delete "${title}"?`)) {
        this.service.removeStep(this.selectedStepId)
        this.selectedStepId = null
      }
    }
  }

  // --- Drag from Palette ---

  handlePaletteDragStart(e) {
    const stepType = e.currentTarget.dataset.stepType
    if (!stepType) return
    e.dataTransfer.setData("text/plain", stepType)
    e.dataTransfer.effectAllowed = "copy"

    // Create a custom drag image for immediate visual feedback
    const ghost = document.createElement("div")
    ghost.textContent = this.capitalize(stepType.replace("_", " "))
    ghost.style.cssText = "position:absolute;top:-9999px;left:-9999px;padding:6px 14px;border-radius:8px;font-size:13px;font-weight:600;color:#fff;white-space:nowrap;pointer-events:none;box-shadow:0 4px 12px rgba(0,0,0,0.15);"
    ghost.style.backgroundColor = this.renderer.getStepColor(stepType)
    document.body.appendChild(ghost)
    e.dataTransfer.setDragImage(ghost, ghost.offsetWidth / 2, ghost.offsetHeight / 2)

    // Clean up the ghost element after the drag starts
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

    const step = this.service.addStep(stepType)
    // Auto-open modal for the new step
    this.openStepModal(step.id)
  }

  // --- Connection Drawing ---

  startConnection(fromStepId, e) {
    this.isConnecting = true
    this.connectionFromId = fromStepId

    const canvasRect = this.canvasTarget.getBoundingClientRect()
    this.connectionStartX = (e.clientX - canvasRect.left + this.canvasTarget.scrollLeft) / this.zoomLevelNum
    this.connectionStartY = (e.clientY - canvasRect.top + this.canvasTarget.scrollTop) / this.zoomLevelNum

    // Highlight input ports on other nodes
    if (this.hasCanvasContentTarget) {
      this.canvasContentTarget.querySelectorAll(".input-port").forEach(port => {
        if (port.dataset.stepId !== fromStepId) {
          port.classList.remove("opacity-0")
          port.classList.add("opacity-100", "bg-green-400", "scale-125")
        }
      })
    }
  }

  updateConnectionLine(e) {
    if (!this.hasTempSvgTarget) return
    const canvasRect = this.canvasTarget.getBoundingClientRect()
    const endX = (e.clientX - canvasRect.left + this.canvasTarget.scrollLeft) / this.zoomLevelNum
    const endY = (e.clientY - canvasRect.top + this.canvasTarget.scrollTop) / this.zoomLevelNum

    // Build temp line via DOM methods for safety (no user content here, just coordinates)
    const line = document.createElementNS("http://www.w3.org/2000/svg", "line")
    line.setAttribute("x1", this.connectionStartX)
    line.setAttribute("y1", this.connectionStartY)
    line.setAttribute("x2", endX)
    line.setAttribute("y2", endY)
    line.setAttribute("stroke", "#6366f1")
    line.setAttribute("stroke-width", "2")
    line.setAttribute("stroke-dasharray", "6,3")
    this.tempSvgTarget.replaceChildren(line)
  }

  finishConnection(e) {
    this.isConnecting = false

    // Clear temp line
    if (this.hasTempSvgTarget) this.tempSvgTarget.replaceChildren()

    // Reset port highlights
    if (this.hasCanvasContentTarget) {
      this.canvasContentTarget.querySelectorAll(".input-port").forEach(port => {
        port.classList.add("opacity-0")
        port.classList.remove("opacity-100", "bg-green-400", "scale-125")
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

    // Check source step type for smart presets
    const sourceStep = this.service.findStep(this.connectionFromId)
    if (sourceStep && sourceStep.type === "question") {
      this.showConditionPopover(e, this.connectionFromId, toStepId, sourceStep)
    } else {
      // Default transition (no condition)
      this.service.addTransition(this.connectionFromId, toStepId, "", "")
    }

    this.connectionFromId = null
  }

  cancelConnection() {
    this.isConnecting = false
    this.connectionFromId = null
    if (this.hasTempSvgTarget) this.tempSvgTarget.replaceChildren()

    // Reset port highlights
    if (this.hasCanvasContentTarget) {
      this.canvasContentTarget.querySelectorAll(".input-port").forEach(port => {
        port.classList.add("opacity-0")
        port.classList.remove("opacity-100", "bg-green-400", "scale-125")
      })
    }
  }

  // --- Condition Popover ---
  // Popover buttons are built with all user text escaped via escapeAttr().

  showConditionPopover(e, fromId, toId, sourceStep) {
    if (!this.hasConditionPopoverTarget || !this.hasConditionOptionsTarget) return

    const presets = this.buildConditionPresets(sourceStep)

    // Build popover buttons using DOM methods
    const container = this.conditionOptionsTarget
    container.replaceChildren()

    presets.forEach(preset => {
      const btn = document.createElement("button")
      btn.type = "button"
      btn.className = "w-full text-left px-3 py-1.5 text-sm rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
      btn.dataset.action = "click->visual-editor#applyConditionPreset"
      btn.dataset.fromId = fromId
      btn.dataset.toId = toId
      btn.dataset.condition = preset.condition
      btn.dataset.label = preset.label
      btn.textContent = preset.displayLabel
      container.appendChild(btn)
    })

    this.conditionPopoverTarget.style.left = `${e.clientX}px`
    this.conditionPopoverTarget.style.top = `${e.clientY}px`
    this.conditionPopoverTarget.classList.remove("hidden")
  }

  hideConditionPopover() {
    if (this.hasConditionPopoverTarget) {
      this.conditionPopoverTarget.classList.add("hidden")
    }
  }

  applyConditionPreset(e) {
    const { fromId, toId, condition, label } = e.currentTarget.dataset
    this.service.addTransition(fromId, toId, condition, label)
    this.hideConditionPopover()
  }

  buildConditionPresets(step) {
    const presets = []
    const answerType = step.answer_type || "text"
    // Use the step's variable_name for condition expressions, fall back to "answer"
    const varName = step.variable_name || "answer"

    switch (answerType) {
      case "yes_no":
        presets.push({ displayLabel: "Yes", condition: `${varName} == 'yes'`, label: "Yes" })
        presets.push({ displayLabel: "No", condition: `${varName} == 'no'`, label: "No" })
        break
      case "multiple_choice":
      case "dropdown":
        if (Array.isArray(step.options)) {
          step.options.forEach(opt => {
            const val = opt.value || opt.label || opt
            presets.push({ displayLabel: val, condition: `${varName} == '${val}'`, label: val })
          })
        }
        break
      case "number":
        presets.push({ displayLabel: "> threshold", condition: `${varName} > 0`, label: "> threshold" })
        presets.push({ displayLabel: "= threshold", condition: `${varName} == '0'`, label: "= threshold" })
        presets.push({ displayLabel: "< threshold", condition: `${varName} < 0`, label: "< threshold" })
        break
    }

    presets.push({ displayLabel: "Default (always)", condition: "", label: "Default" })
    return presets
  }

  // --- Step Modal ---

  openStepModal(stepId) {
    const step = this.service.findStep(stepId)
    if (!step) return

    this.editingStepId = stepId

    if (this.hasModalTitleTarget) {
      this.modalTitleTarget.textContent = `Edit ${this.capitalize(step.type || 'Step')}`
    }

    if (this.hasModalBodyTarget) {
      // Build modal form using DOM methods for safety
      this.modalBodyTarget.replaceChildren()
      this.buildStepFormDOM(step, this.modalBodyTarget)
    }

    if (this.hasStepModalTarget) {
      this.stepModalTarget.classList.remove("hidden")
    }
  }

  closeModal() {
    if (this.hasStepModalTarget) {
      this.stepModalTarget.classList.add("hidden")
    }
    this.editingStepId = null
  }

  saveModal() {
    if (!this.editingStepId || !this.hasModalBodyTarget) return

    const form = this.modalBodyTarget
    const data = {}

    // Read common fields
    const titleInput = form.querySelector('[name="step-title"]')
    if (titleInput) data.title = titleInput.value

    const descInput = form.querySelector('[name="step-description"]')
    if (descInput) data.description = descInput.value

    // Read type-specific fields
    const step = this.service.findStep(this.editingStepId)
    if (step) {
      switch (step.type) {
        case "question":
          this.readField(form, "step-question", data, "question")
          this.readField(form, "step-answer-type", data, "answer_type")
          this.readField(form, "step-variable-name", data, "variable_name")
          break
        case "action":
          this.readField(form, "step-action-type", data, "action_type")
          this.readField(form, "step-instructions", data, "instructions")
          break
        case "message":
          this.readField(form, "step-content", data, "content")
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

    this.service.updateStep(this.editingStepId, data)
    this.closeModal()
  }

  readField(form, name, data, key) {
    const el = form.querySelector(`[name="${name}"]`)
    if (el) data[key] = el.value
  }

  deleteStepFromModal() {
    if (!this.editingStepId) return
    const step = this.service.findStep(this.editingStepId)
    const title = step ? step.title : "this step"
    if (confirm(`Delete "${title}"?`)) {
      this.service.removeStep(this.editingStepId)
      this.closeModal()
    }
  }

  // Build modal form using safe DOM methods (no innerHTML with user data)
  buildStepFormDOM(step, container) {
    const wrapper = document.createElement("div")
    wrapper.className = "space-y-4"

    // Title field
    wrapper.appendChild(this.createTextField("Title", "step-title", step.title || ""))

    // Description field
    wrapper.appendChild(this.createTextareaField("Description", "step-description", step.description || "", 2))

    // Type-specific fields
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
        break
      case "message":
        wrapper.appendChild(this.createTextareaField("Message Content", "step-content", step.content || "", 4))
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
    const lbl = document.createElement("label")
    lbl.className = "block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1"
    lbl.textContent = label
    div.appendChild(lbl)

    const input = document.createElement("input")
    input.type = "text"
    input.name = name
    input.value = value
    input.className = "w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
    div.appendChild(input)
    return div
  }

  createTextareaField(label, name, value, rows) {
    const div = document.createElement("div")
    const lbl = document.createElement("label")
    lbl.className = "block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1"
    lbl.textContent = label
    div.appendChild(lbl)

    const textarea = document.createElement("textarea")
    textarea.name = name
    textarea.rows = rows
    textarea.value = value
    textarea.textContent = value
    textarea.className = "w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
    div.appendChild(textarea)
    return div
  }

  createSelectField(label, name, selectedValue, options) {
    const div = document.createElement("div")
    const lbl = document.createElement("label")
    lbl.className = "block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1"
    lbl.textContent = label
    div.appendChild(lbl)

    const select = document.createElement("select")
    select.name = name
    select.className = "w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"

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

  // --- Mode Switching Helpers ---

  loadFromListForm() {
    const container = document.querySelector("#list-editor-container [data-workflow-builder-target='container']")
    if (!container) return

    const stepItems = container.querySelectorAll(".step-item")
    const steps = []

    // Build a lookup of existing transitions and options by step ID
    // so we can preserve them when syncing from the list form
    const existingStepMap = {}
    if (this.service && this.service.steps) {
      this.service.steps.forEach(s => {
        existingStepMap[s.id] = s
      })
    }

    stepItems.forEach((item) => {
      const step = {}
      step.id = this.readInputValue(item, "[name*='[id]']") || crypto.randomUUID()
      step.type = this.readInputValue(item, "[name*='[type]']") || "question"
      step.title = this.readInputValue(item, "[name*='[title]']") || ""
      step.description = this.readInputValue(item, "[name*='[description]']") || ""
      step.question = this.readInputValue(item, "[name*='[question]']") || ""
      step.answer_type = this.readInputValue(item, "[name*='[answer_type]']") || "yes_no"
      step.variable_name = this.readInputValue(item, "[name*='[variable_name]']") || ""
      step.action_type = this.readInputValue(item, "[name*='[action_type]']") || ""
      step.instructions = this.readInputValue(item, "[name*='[instructions]']") || ""
      step.content = this.readInputValue(item, "[name*='[content]']") || ""
      step.target_workflow_id = this.readInputValue(item, "[name*='[target_workflow_id]']") || ""

      // Read transitions from list form's transitions_json hidden field
      const transitionsJson = this.readInputValue(item, "[name*='[transitions_json]']")
      if (transitionsJson) {
        try {
          step.transitions = JSON.parse(transitionsJson)
        } catch (e) {
          step.transitions = []
        }
      } else {
        // Preserve existing transitions from the visual editor service
        const existing = existingStepMap[step.id]
        step.transitions = existing ? (existing.transitions || []) : []
      }

      // Read options from list form (multiple_choice / dropdown steps)
      const optionLabels = item.querySelectorAll("[name*='[options][][label]']")
      const optionValues = item.querySelectorAll("[name*='[options][][value]']")
      if (optionLabels.length > 0) {
        step.options = []
        optionLabels.forEach((labelEl, idx) => {
          const label = labelEl.value || ""
          const value = optionValues[idx] ? optionValues[idx].value : label
          if (label || value) {
            step.options.push({ label, value })
          }
        })
      } else {
        // Preserve existing options from the visual editor service
        const existing = existingStepMap[step.id]
        if (existing && existing.options) {
          step.options = existing.options
        }
      }

      steps.push(step)
    })

    const startNodeUuid = this.hasStartNodeInputTarget ? this.startNodeInputTarget.value : undefined
    this.service = new VisualEditorService(steps, {
      startNodeUuid,
      onChange: () => this.handleServiceChange()
    })
    this.render()
  }

  readInputValue(container, selector) {
    const el = container.querySelector(selector)
    return el ? el.value : null
  }

  syncToListForm() {
    this.syncHiddenInputs()
  }

  isDirty() {
    return this.service ? this.service.dirty : false
  }

  // --- Utilities ---

  escapeAttr(text) {
    if (!text) return ''
    return String(text)
      .replace(/&/g, '&amp;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
  }

  capitalize(str) {
    if (!str) return ''
    return str.charAt(0).toUpperCase() + str.slice(1).replace(/_/g, ' ')
  }
}
