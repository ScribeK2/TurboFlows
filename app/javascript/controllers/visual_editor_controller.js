import { Controller } from "@hotwired/stimulus"
import { FlowchartRenderer } from "services/flowchart_renderer"
import { VisualEditorService } from "services/visual_editor_service"

// Main orchestrator for the visual workflow editor.
// Owns FlowchartRenderer, VisualEditorService, persistence, rendering,
// node selection, and event routing to child controllers:
//   - canvas-zoom (zoom/pan)
//   - ve-step-modal (step editing modal)
//   - ve-connection (connection drawing, condition popover, palette drag)
//
// XSS Safety: All user-provided content is escaped via the renderer's
// escapeHtml() for HTML contexts. Child controllers use safe DOM methods
// (createElement, textContent) for all user-facing content.
export default class extends Controller {
  static targets = [
    "root", "canvas", "canvasContent", "emptyState", "stepsData",
    "stepsInput", "startNodeInput", "stepCount"
  ]

  static values = {
    workflowId: Number,
    lockVersion: Number,
    mode: { type: String, default: "visual" },
    wizardNextUrl: { type: String, default: "" }
  }

  connect() {
    this.renderer = new FlowchartRenderer({
      interactive: true,
      arrowIdPrefix: 'visual-',
      nodeWidth: 200,
      nodeHeight: 120
    })

    this.isConnecting = false
    this.selectedStepId = null

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

    // Intercept form submission — save via sync_steps API when visual editor is active
    this.boundFormSubmit = (e) => {
      if (this.element.classList.contains("is-hidden")) {
        this.syncHiddenInputs()
        this.service.dirty = false
        return
      }

      e.preventDefault()
      this.saveToServer()
    }
    const form = this.element.closest("form")
    if (form) {
      form.addEventListener("submit", this.boundFormSubmit, true)
    }

    // Listen for child controller events
    this.element.addEventListener("visual-editor:auto-arrange", () => this.render())
    this.element.addEventListener("visual-editor:step-saved", (e) => this.handleStepSaved(e))
    this.element.addEventListener("visual-editor:step-deleted", (e) => this.handleStepDeleted(e))
    this.element.addEventListener("visual-editor:add-transition", (e) => this.handleAddTransition(e))
    this.element.addEventListener("visual-editor:add-step", (e) => this.handleAddStep(e))

    this.render()
  }

  disconnect() {
    window.removeEventListener("beforeunload", this.boundBeforeUnload)
    const form = this.element.closest("form")
    if (form) {
      form.removeEventListener("submit", this.boundFormSubmit, true)
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
      if (this.hasEmptyStateTarget) this.emptyStateTarget.classList.remove("is-hidden")
      if (this.hasCanvasContentTarget) this.canvasContentTarget.textContent = ""
      this.updateStepCount(0)
      return
    }

    if (this.hasEmptyStateTarget) this.emptyStateTarget.classList.add("is-hidden")

    // Renderer output is built from escapeHtml-protected internal methods.
    // This is the same trusted rendering used by flow_preview_controller.
    const html = this.renderer.render(steps)
    if (this.hasCanvasContentTarget) {
      this.canvasContentTarget.replaceChildren()
      this.canvasContentTarget.insertAdjacentHTML("afterbegin", html)
    }

    this.updateStepCount(steps.length)
    this.highlightOrphans()
    this.highlightSelected()
    this.attachNodeEventListeners()

    // Notify child controllers (canvas-zoom applies zoom, etc.)
    this.element.dispatchEvent(new CustomEvent("visual-editor:rendered", { bubbles: false }))
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
    document.dispatchEvent(new CustomEvent("workflow:updated"))
  }

  async saveToServer() {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    const url = `/workflows/${this.workflowIdValue}/sync_steps`

    const form = this.element.closest("form")
    const titleInput = form?.querySelector("input[name='workflow[title]']")
    const descField = form?.querySelector("[name='workflow[description]']")

    const lockInput = form?.querySelector("input[name='workflow[lock_version]']")
    const currentLockVersion = lockInput ? parseInt(lockInput.value, 10) : this.lockVersionValue

    const payload = {
      steps: this.service.steps,
      start_node_uuid: this.service.startNodeUuid,
      lock_version: currentLockVersion,
      title: titleInput?.value,
      description: descField?.value
    }

    try {
      const response = await fetch(url, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken || "",
          "Accept": "application/json"
        },
        credentials: "same-origin",
        body: JSON.stringify(payload)
      })

      if (response.ok) {
        const data = await response.json()
        this.lockVersionValue = data.lock_version
        this.service.dirty = false

        const lockInput = this.element.closest("form")?.querySelector("input[name='workflow[lock_version]']")
        if (lockInput) lockInput.value = data.lock_version

        if (this.wizardNextUrlValue) {
          window.location.href = this.wizardNextUrlValue
          return
        }

        window.location.href = `/workflows/${this.workflowIdValue}`
        return
      } else if (response.status === 409) {
        this.showFlash("This workflow was modified by another user. Please refresh and try again.", "error")
      } else {
        const data = await response.json().catch(() => ({}))
        this.showFlash(data.error || "Failed to save workflow.", "error")
      }
    } catch (error) {
      console.error("[VisualEditor] Save failed:", error)
      this.showFlash("Network error. Please try again.", "error")
    }
  }

  showFlash(message, type) {
    const statusEl = document.querySelector("[data-autosave-target='status']")
    if (statusEl) {
      statusEl.textContent = message
      statusEl.classList.toggle("status--success", type === "success")
      statusEl.classList.toggle("status--error", type === "error")

      setTimeout(() => {
        statusEl.textContent = "Ready to save"
        statusEl.classList.remove("status--success", "status--error")
      }, 3000)
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
        if (e.target.closest(".output-port") || e.target.closest(".input-port")) return
        e.stopPropagation()
        this.selectNode(stepId)
      })

      node.addEventListener("dblclick", (e) => {
        e.stopPropagation()
        const step = this.service.findStep(stepId)
        if (step) {
          this.element.dispatchEvent(new CustomEvent("visual-editor:open-modal", {
            bubbles: false,
            detail: { step: { ...step } }
          }))
        }
      })

      // Output port: dispatch to connection controller
      const outputPort = node.querySelector(".output-port")
      if (outputPort) {
        outputPort.addEventListener("mousedown", (e) => {
          e.stopPropagation()
          e.preventDefault()
          this.element.dispatchEvent(new CustomEvent("visual-editor:start-connection", {
            bubbles: false,
            detail: { stepId, event: e }
          }))
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
        card.classList.add("is-selected")
      } else {
        card.classList.remove("is-selected")
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
        card.classList.add("is-orphan")
      } else {
        card.classList.remove("is-orphan")
      }
    })
  }

  // --- Canvas Click (deselect) ---

  handleCanvasClick(e) {
    if (e.target === this.canvasTarget || e.target === this.canvasContentTarget) {
      this.deselectAll()
    }
  }

  // --- Keyboard Dispatch ---

  handleKeyDown(e) {
    if (e.key === "Escape") {
      // Check connection state via data attribute set by ve-connection controller
      if (this.element.dataset.connecting === "true") {
        this.element.dispatchEvent(new CustomEvent("visual-editor:cancel-connection", { bubbles: false }))
      } else {
        this.element.dispatchEvent(new CustomEvent("visual-editor:close-modal", { bubbles: false }))
        this.element.dispatchEvent(new CustomEvent("visual-editor:hide-popover", { bubbles: false }))
      }
      return
    }

    if ((e.key === "Delete" || e.key === "Backspace") && this.selectedStepId) {
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

  // --- Child Controller Event Handlers ---

  handleStepSaved(e) {
    const { stepId, data } = e.detail
    this.service.updateStep(stepId, data)
    this.render()
    this.syncHiddenInputs()
  }

  handleStepDeleted(e) {
    const { stepId } = e.detail
    this.service.removeStep(stepId)
  }

  handleAddTransition(e) {
    const { fromId, toId, condition, label } = e.detail
    this.service.addTransition(fromId, toId, condition, label)
  }

  handleAddStep(e) {
    const { type } = e.detail
    const step = this.service.addStep(type)
    this.element.dispatchEvent(new CustomEvent("visual-editor:open-modal", {
      bubbles: false,
      detail: { step: { ...step } }
    }))
  }

  // --- Mode Switching Helpers ---

  loadFromListForm() {
    if (this.service && this.service.dirty) {
      const overwrite = confirm(
        "The visual editor has unsaved changes. Loading from the list view will discard them. Continue?"
      )
      if (!overwrite) return
    }

    const container = document.querySelector("#list-editor-container [data-workflow-builder-target='container']")
    if (!container) return

    const stepItems = container.querySelectorAll(".step-item")
    const steps = []

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

      const transitionsJson = this.readInputValue(item, "[name*='[transitions_json]']")
      if (transitionsJson) {
        try {
          step.transitions = JSON.parse(transitionsJson)
        } catch (e) {
          step.transitions = []
        }
      } else {
        const existing = existingStepMap[step.id]
        step.transitions = existing ? (existing.transitions || []) : []
      }

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

  // Expose service.findStep for connection controller's popover presets
  findStep(stepId) {
    return this.service ? this.service.findStep(stepId) : null
  }

  capitalize(str) {
    if (!str) return ''
    return str.charAt(0).toUpperCase() + str.slice(1).replace(/_/g, ' ')
  }
}
