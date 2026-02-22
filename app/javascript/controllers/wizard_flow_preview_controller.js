import { Controller } from "@hotwired/stimulus"
import { FlowchartRenderer } from "services/flowchart_renderer"

// Wizard-specific flow preview controller for step3
// Reads steps from workflow data instead of form inputs
export default class extends Controller {
  static targets = ["canvas"]
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

    // Load steps from script tag (safer than HTML attributes for complex JSON)
    this.loadStepsFromScript()
    // Delay initial render to ensure DOM is ready
    setTimeout(() => {
      this.render()
    }, 100)
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

  render() {
    const steps = this.getSteps()
    if (!steps || steps.length === 0) {
      this.canvasTarget.innerHTML = '<p class="text-gray-500 dark:text-gray-400 text-center py-8">No steps to preview. Add steps to see the flowchart.</p>'
      return
    }

    const html = this.buildFlowchartHtml(steps)
    this.canvasTarget.innerHTML = html
  }

  // Build HTML for flowchart with click-to-edit functionality
  // Uses shared renderer for connections and positions, but custom node rendering
  buildFlowchartHtml(steps) {
    const connections = this.renderer.buildConnections(steps)
    const positions = this.renderer.calculatePositions(steps, connections)

    if (Object.keys(positions).length === 0) {
      return '<p class="text-gray-500 dark:text-gray-400 text-center py-8">Unable to render flow preview</p>'
    }

    // Calculate canvas dimensions
    const positionValues = Object.values(positions)
    const nodeWidth = this.renderer.nodeWidth
    const nodeHeight = this.renderer.nodeHeight
    const nodeMargin = this.renderer.nodeMargin
    const maxX = Math.max(...positionValues.map(p => p.x + nodeWidth)) + nodeMargin
    const maxY = Math.max(...positionValues.map(p => p.y + nodeHeight)) + nodeMargin

    // Build SVG connections
    let svgHtml = this.renderer.buildConnectionsSvg(connections, positions, maxX, maxY)

    // Build nodes with click-to-edit functionality
    let nodesHtml = `<div class="relative" style="min-height: ${maxY}px; width: ${maxX}px;">`
    nodesHtml += svgHtml

    steps.forEach((step, arrayIndex) => {
      const pos = positions[arrayIndex] || positions[step.index]
      if (!pos) return

      const bgColor = this.renderer.getStepColor(step.type)

      nodesHtml += `
        <div class="absolute workflow-node z-10 cursor-pointer hover:opacity-80 transition-opacity"
             style="left: ${pos.x}px; top: ${pos.y}px; width: ${nodeWidth}px;"
             data-step-index="${step.index}"
             data-action="click->wizard-flow-preview#editStep">
          <div class="border-2 rounded-lg p-3 bg-white dark:bg-gray-800 shadow-sm"
               style="border-color: ${bgColor}; min-height: ${nodeHeight}px;">
            <div class="flex items-center mb-2">
              <span class="inline-flex items-center justify-center w-6 h-6 rounded-full text-xs font-semibold text-white mr-2" style="background-color: ${bgColor};">
                ${step.index + 1}
              </span>
              <span class="text-xs font-medium uppercase text-gray-600 dark:text-gray-400">${this.renderer.escapeHtml(step.type || 'unknown')}</span>
            </div>
            <h4 class="font-semibold text-sm text-gray-900 dark:text-gray-100 mb-1 break-words">${this.renderer.escapeHtml(step.title || `Step ${step.index + 1}`)}</h4>
            <p class="text-xs text-gray-500 dark:text-gray-500 mt-2">Click to edit</p>
          </div>
        </div>
      `
    })

    nodesHtml += "</div>"
    return nodesHtml
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
