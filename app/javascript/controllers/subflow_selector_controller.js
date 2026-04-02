import { Controller } from "@hotwired/stimulus"

/**
 * Controller for selecting a target workflow for sub-flow steps.
 * Fetches available published workflows and populates the dropdown.
 */
export default class extends Controller {
  static targets = ["select", "hiddenInput"]
  static values = {
    currentWorkflowId: String
  }

  connect() {
    this.loadWorkflows()
  }

  async loadWorkflows() {
    if (!this.hasSelectTarget) return

    try {
      const response = await fetch("/workflows.json?published=true", {
        headers: {
          'Accept': 'application/json'
        }
      })

      if (!response.ok) {
        console.error("[SubflowSelector] Failed to load workflows:", response.status)
        return
      }

      const workflows = await response.json()
      this.populateDropdown(workflows)
    } catch (error) {
      console.error("[SubflowSelector] Error loading workflows:", error)
    }
  }

  populateDropdown(workflows) {
    const select = this.selectTarget
    const currentValue = this.hasHiddenInputTarget ? this.hiddenInputTarget.value : ""
    const currentWorkflowId = this.currentWorkflowIdValue

    // Clear existing options except the placeholder
    const placeholderOpt = document.createElement('option')
    placeholderOpt.value = ""
    placeholderOpt.textContent = "-- Select a workflow --"
    select.replaceChildren(placeholderOpt)

    // Filter out the current workflow (can't reference itself)
    const filteredWorkflows = workflows.filter(w =>
      String(w.id) !== String(currentWorkflowId)
    )

    // Add workflow options
    filteredWorkflows.forEach(workflow => {
      const option = document.createElement('option')
      option.value = workflow.id
      option.textContent = workflow.title
      option.selected = String(workflow.id) === String(currentValue)
      select.appendChild(option)
    })

    // If current value exists but wasn't in the list, add it as selected
    if (currentValue && !filteredWorkflows.find(w => String(w.id) === String(currentValue))) {
      const option = document.createElement('option')
      option.value = currentValue
      option.textContent = `Workflow #${currentValue} (not found)`
      option.selected = true
      select.appendChild(option)
    }
  }

  selectWorkflow(event) {
    const selectedId = event.target.value

    if (this.hasHiddenInputTarget) {
      this.hiddenInputTarget.value = selectedId
    }

    // Dispatch event for other components
    document.dispatchEvent(new CustomEvent("subflow:selected", {
      detail: {
        workflowId: selectedId,
        workflowTitle: event.target.options[event.target.selectedIndex]?.textContent
      }
    }))
  }
}
