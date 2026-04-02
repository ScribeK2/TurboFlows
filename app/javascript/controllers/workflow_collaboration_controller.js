import { Controller } from "@hotwired/stimulus"
import { subscribeToWorkflow } from "channels/workflow_channel"

export default class extends Controller {
  static targets = ["container", "presence"]
  static values = { 
    workflowId: Number,
    currentUserId: Number,
    container: String
  }

  connect() {
    if (!this.workflowIdValue) {
      console.warn("WorkflowCollaborationController: No workflow ID provided")
      return
    }

    // Find the container target (workflow-builder container)
    if (this.hasContainerValue) {
      const containerSelector = this.containerValue || "[data-workflow-builder-target='container']"
      const foundContainer = this.element.querySelector(containerSelector)
      if (foundContainer) {
        // Create a reference to the container
        this.containerElement = foundContainer
      }
    }

    // Subscribe to workflow channel
    this.subscription = subscribeToWorkflow(this.workflowIdValue, {
      connected: () => {

        this.updateConnectionStatus(true)
      },
      disconnected: () => {

        this.updateConnectionStatus(false)
      },
      presence: (data) => {

        this.handlePresenceUpdate(data)
      },
      update: (data) => {
        // Update callback handled via document event listeners
      }
    })
    

    // Set up event listeners for real-time updates
    this.setupEventListeners()
    
    // Track if we're currently applying remote changes (to avoid feedback loops)
    this.applyingRemoteChange = false
  }

  disconnect() {
    if (this.subscription) {
      this.subscription.unsubscribe()
    }
    this.removeEventListeners()
  }

  setupEventListeners() {
    // Listen for step updates from other users (from ActionCable)
    this.stepUpdateHandler = (event) => {
      if (!this.isFromCurrentUser(event.detail.user)) {
        this.handleStepUpdate(event.detail)
      }
    }
    
    // Listen for step additions from other users (from ActionCable)
    this.stepAddedHandler = (event) => {
      if (!this.isFromCurrentUser(event.detail.user)) {
        this.handleStepAdded(event.detail)
      }
    }
    
    // Listen for step removals from other users (from ActionCable)
    this.stepRemovedHandler = (event) => {
      if (!this.isFromCurrentUser(event.detail.user)) {
        this.handleStepRemoved(event.detail)
      }
    }
    
    // Listen for step reordering from other users (from ActionCable)
    this.stepsReorderedHandler = (event) => {
      if (!this.isFromCurrentUser(event.detail.user)) {
        this.handleStepsReordered(event.detail)
      }
    }
    
    // Listen for metadata updates from other users (from ActionCable)
    this.metadataUpdateHandler = (event) => {
      if (!this.isFromCurrentUser(event.detail.user)) {
        this.handleMetadataUpdate(event.detail)
      }
    }
    
    // Listen for presence updates (from ActionCable)
    this.presenceHandler = (event) => {
      this.handlePresenceUpdate(event.detail)
    }

    // Listen for local changes from workflow-builder and broadcast them
    this.localStepAddedHandler = (event) => {
      if (!this.applyingRemoteChange && this.subscription) {
        this.subscription.broadcastStepAdded(
          event.detail.stepIndex,
          event.detail.stepType,
          event.detail.stepData
        )
      }
    }
    
    this.localStepRemovedHandler = (event) => {
      if (!this.applyingRemoteChange && this.subscription) {
        this.subscription.broadcastStepRemoved(event.detail.stepIndex)
      }
    }
    
    this.localStepsReorderedHandler = (event) => {
      if (!this.applyingRemoteChange && this.subscription) {
        this.subscription.broadcastStepsReordered(event.detail.newOrder)
      }
    }

    // Listen for step field updates (debounced)
    this.setupStepFieldListeners()

    document.addEventListener("workflow:step_update", this.stepUpdateHandler)
    document.addEventListener("workflow:step_added", this.stepAddedHandler)
    document.addEventListener("workflow:step_removed", this.stepRemovedHandler)
    document.addEventListener("workflow:steps_reordered", this.stepsReorderedHandler)
    document.addEventListener("workflow:workflow_metadata_update", this.metadataUpdateHandler)
    document.addEventListener("workflow:presence", this.presenceHandler)
    
    // Listen for local workflow-builder events
    document.addEventListener("workflow-builder:step-added", this.localStepAddedHandler)
    document.addEventListener("workflow-builder:step-removed", this.localStepRemovedHandler)
    document.addEventListener("workflow-builder:steps-reordered", this.localStepsReorderedHandler)
  }

  removeEventListeners() {
    document.removeEventListener("workflow:step_update", this.stepUpdateHandler)
    document.removeEventListener("workflow:step_added", this.stepAddedHandler)
    document.removeEventListener("workflow:step_removed", this.stepRemovedHandler)
    document.removeEventListener("workflow:steps_reordered", this.stepsReorderedHandler)
    document.removeEventListener("workflow:workflow_metadata_update", this.metadataUpdateHandler)
    document.removeEventListener("workflow:presence", this.presenceHandler)
    document.removeEventListener("workflow-builder:step-added", this.localStepAddedHandler)
    document.removeEventListener("workflow-builder:step-removed", this.localStepRemovedHandler)
    document.removeEventListener("workflow-builder:steps-reordered", this.localStepsReorderedHandler)
    
    const container = this.containerElement || this.containerTarget || this.element.querySelector("[data-workflow-builder-target='container']")
    if (container) {
      container.removeEventListener("input", this.stepFieldUpdateHandler)
    }
    
    // Remove description listeners
    const descriptionInput = this.element.querySelector("textarea[name='workflow[description]']")
    if (descriptionInput && this.descriptionUpdateHandler) {
      descriptionInput.removeEventListener("input", this.descriptionUpdateHandler)
    }
    
    if (this.descriptionDebounceTimer) {
      clearTimeout(this.descriptionDebounceTimer)
    }
    
    if (this.stepFieldDebounceTimer) {
      clearTimeout(this.stepFieldDebounceTimer)
    }
    
    const titleInput = this.element.querySelector("input[name='workflow[title]']")
    if (titleInput) {
      titleInput.removeEventListener("input", this.titleUpdateHandler)
    }
  }

  setupStepFieldListeners() {
    const container = this.containerElement || this.containerTarget || this.element.querySelector("[data-workflow-builder-target='container']")
    if (!container) return
    
    // Debounce step field updates
    this.stepFieldUpdateHandler = (event) => {
      if (this.applyingRemoteChange) return
      
      const stepElement = event.target.closest(".step-item")
      if (!stepElement) return
      
      const stepIndex = parseInt(stepElement.getAttribute("data-step-index") || "0")
      
      // Clear existing timer
      if (this.stepFieldDebounceTimer) {
        clearTimeout(this.stepFieldDebounceTimer)
      }
      
      // Debounce updates (wait 500ms after last change)
      this.stepFieldDebounceTimer = setTimeout(() => {
        if (!this.applyingRemoteChange && this.subscription) {
          const stepData = this.extractStepData(stepElement)

          this.subscription.broadcastStepUpdate(stepIndex, stepData)
        }
      }, 500)
    }
    
    container.addEventListener("input", this.stepFieldUpdateHandler)
    
    // Listen for title changes
    const titleInput = this.element.querySelector("input[name='workflow[title]']")
    if (titleInput) {
      this.titleUpdateHandler = (event) => {
        if (this.applyingRemoteChange) return
        
        if (this.titleDebounceTimer) {
          clearTimeout(this.titleDebounceTimer)
        }
        
        this.titleDebounceTimer = setTimeout(() => {
          if (!this.applyingRemoteChange && this.subscription) {

            this.subscription.broadcastMetadataUpdate("title", event.target.value)
          }
        }, 500)
      }
      
      titleInput.addEventListener("input", this.titleUpdateHandler)
    }
    
    // Listen for description textarea changes
    const descriptionInput = this.element.querySelector("textarea[name='workflow[description]']")
    if (descriptionInput) {
      this.descriptionUpdateHandler = (event) => {
        if (this.applyingRemoteChange) return

        if (this.descriptionDebounceTimer) {
          clearTimeout(this.descriptionDebounceTimer)
        }

        this.descriptionDebounceTimer = setTimeout(() => {
          if (!this.applyingRemoteChange && this.subscription) {
            const value = descriptionInput.value || ""

            this.subscription.broadcastMetadataUpdate("description", value)
          }
        }, 500)
      }

      descriptionInput.addEventListener("input", this.descriptionUpdateHandler)
    }
  }

  extractStepData(stepElement) {
    if (!stepElement) return {}
    
    const data = {}
    
    const titleInput = stepElement.querySelector("input[name*='[title]']")
    if (titleInput) data.title = titleInput.value
    
    const descInput = stepElement.querySelector("textarea[name*='[description]']")
    if (descInput) data.description = descInput.value
    
    const typeInput = stepElement.querySelector("input[name*='[type]']")
    if (typeInput) data.type = typeInput.value
    
    if (data.type === "question") {
      const questionInput = stepElement.querySelector("input[name*='[question]']")
      if (questionInput) data.question = questionInput.value
    } else if (data.type === "action") {
      const instructionsInput = stepElement.querySelector("textarea[name*='[instructions]']")
      if (instructionsInput) data.instructions = instructionsInput.value
    }
    
    return data
  }

  isFromCurrentUser(user) {
    return user && user.id === this.currentUserIdValue
  }

  handleStepUpdate(data) {
    this.applyingRemoteChange = true
    const stepElement = this.findStepElement(data.step_index)
    if (stepElement) {
      // Update step fields with new data
      this.updateStepFields(stepElement, data.step_data)
      this.showUpdateIndicator(stepElement, data.user)
    }
    setTimeout(() => { this.applyingRemoteChange = false }, 100)
  }

  handleStepAdded(data) {
    this.applyingRemoteChange = true
    // Find the workflow builder controller and trigger it to add a step
    const container = this.containerElement || this.containerTarget || this.element.querySelector("[data-workflow-builder-target='container']")
    if (!container) return
    
    const workflowBuilderElement = container.closest("[data-controller*='workflow-builder']")
    if (workflowBuilderElement) {
      const application = window.Stimulus
      if (application) {
        const controller = application.getControllerForElementAndIdentifier(workflowBuilderElement, "workflow-builder")
        if (controller && typeof controller.buildStepHtml === 'function') {
          // Insert the step HTML at the correct index
          const stepHtml = controller.buildStepHtml(data.step_type, data.step_index, data.step_data || {})
          const existingSteps = container.querySelectorAll(".step-item")
          
          if (data.step_index >= existingSteps.length) {
            // Append at the end
            container.insertAdjacentHTML("beforeend", stepHtml)
          } else {
            // Insert before the step at the target index
            const targetStep = existingSteps[data.step_index]
            if (targetStep) {
              targetStep.insertAdjacentHTML("beforebegin", stepHtml)
            } else {
              container.insertAdjacentHTML("beforeend", stepHtml)
            }
          }
          
          // Update indices
          const updateEvent = new CustomEvent("workflow:update-indices")
          document.dispatchEvent(updateEvent)
          
          // Refresh dropdowns
          if (typeof controller.refreshAllDropdowns === 'function') {
            controller.refreshAllDropdowns()
          }
          
          this.showNotification(`${data.user.name || data.user.email} added a step`, "info")
        }
      }
    }
    setTimeout(() => { this.applyingRemoteChange = false }, 100)
  }

  handleStepRemoved(data) {
    this.applyingRemoteChange = true
    const stepElement = this.findStepElement(data.step_index)
    if (stepElement) {
      this.showRemoveIndicator(stepElement, data.user)
      setTimeout(() => {
        stepElement.remove()
        this.updateStepIndices()
      }, 500)
    }
    setTimeout(() => { this.applyingRemoteChange = false }, 600)
  }

  handleStepsReordered(data) {
    this.applyingRemoteChange = true
    // Apply new order to steps
    const container = this.containerElement || this.containerTarget || this.element.querySelector("[data-workflow-builder-target='container']")
    if (!container) return
    const steps = Array.from(container.querySelectorAll(".step-item"))
    
    // Reorder steps based on new_order array
    data.new_order.forEach((stepIndex, newPosition) => {
      const stepElement = steps.find(step => {
        const indexInput = step.querySelector("input[name*='[index]']")
        return indexInput && parseInt(indexInput.value) === stepIndex
      })
      if (stepElement) {
        container.insertBefore(stepElement, container.children[newPosition])
      }
    })
    
    this.updateStepIndices()
    setTimeout(() => { this.applyingRemoteChange = false }, 100)
  }

  handleMetadataUpdate(data) {
    this.applyingRemoteChange = true
    const field = data.field
    const value = data.value
    
    if (field === "title") {
      const titleInput = this.element.querySelector("input[name='workflow[title]']")
      if (titleInput && titleInput.value !== value) {
        titleInput.value = value
        // Dispatch event with remoteUpdate flag
        const customEvent = new CustomEvent("input", { 
          bubbles: true,
          detail: { remoteUpdate: true }
        })
        titleInput.dispatchEvent(customEvent)
        this.showUpdateIndicator(titleInput.closest("div"), data.user)
      }
    } else if (field === "description") {
      const textarea = this.element.querySelector("textarea[name='workflow[description]']")
      if (textarea && textarea.value !== value) {
        textarea.value = value
        this.showUpdateIndicator(textarea.closest("div"), data.user)
      }
    }
    setTimeout(() => { this.applyingRemoteChange = false }, 100)
  }

  handlePresenceUpdate(data) {
    if (this.hasPresenceTarget) {
      this.updatePresenceDisplay(data.active_users || [])
    }
  }

  findStepElement(index) {
    const container = this.containerElement || this.containerTarget || this.element.querySelector("[data-workflow-builder-target='container']")
    if (!container) return null
    const steps = container.querySelectorAll(".step-item")
    return steps[index] || null
  }

  updateStepFields(stepElement, stepData) {
    // Set flag to prevent autosave from triggering during remote updates
    this.applyingRemoteChange = true
    
    // Update title
    const titleInput = stepElement.querySelector("input[name*='[title]']")
    if (titleInput && stepData.title !== undefined) {
      titleInput.value = stepData.title
    }
    
    // Update description
    const descInput = stepElement.querySelector("textarea[name*='[description]']")
    if (descInput && stepData.description !== undefined) {
      descInput.value = stepData.description
    }
    
    // Update other fields based on step type
    // This would need to be expanded based on step type
    if (stepData.question !== undefined) {
      const questionInput = stepElement.querySelector("input[name*='[question]']")
      if (questionInput) questionInput.value = stepData.question
    }
    
    if (stepData.instructions !== undefined) {
      const instructionsInput = stepElement.querySelector("textarea[name*='[instructions]']")
      if (instructionsInput) instructionsInput.value = stepData.instructions
    }
    
    // Reset flag after a short delay to allow DOM updates to complete
    setTimeout(() => {
      this.applyingRemoteChange = false
    }, 100)
    
    // Trigger change event to update previews (but not autosave)
    const changeEvent = new Event("input", { bubbles: true })
    stepElement.querySelectorAll("input, textarea").forEach(input => {
      // Dispatch event but mark it so autosave can ignore it
      const customEvent = new CustomEvent("input", { 
        bubbles: true,
        detail: { remoteUpdate: true }
      })
      input.dispatchEvent(customEvent)
    })
  }

  updateStepIndices() {
    if (!this.hasContainerTarget) return
    const steps = this.containerTarget.querySelectorAll(".step-item")
    steps.forEach((step, index) => {
      const indexInput = step.querySelector("input[name*='[index]']")
      if (indexInput) {
        indexInput.value = index
      }
      step.setAttribute("data-step-index", index)
    })
  }

  showUpdateIndicator(element, user) {
    if (!element) return

    // Add visual indicator
    element.classList.add("is-updated")

    setTimeout(() => {
      element.classList.remove("is-updated")
    }, 2000)
    
    // Show a toast notification
    this.showNotification(`${user.name || user.email} updated this step`, "info")
  }

  showRemoveIndicator(element, user) {
    if (!element) return
    
    element.style.transition = "opacity 0.5s"
    element.style.opacity = "0.5"
    
    this.showNotification(`${user.name || user.email} removed this step`, "info")
  }

  updatePresenceDisplay(activeUsers) {
    if (!this.hasPresenceTarget) return

    // Filter out current user
    const otherUsers = activeUsers.filter(u => u.id !== this.currentUserIdValue)

    if (otherUsers.length === 0) {
      this.presenceTarget.replaceChildren()
      return
    }

    // Build presence UI via DOM API to avoid XSS from user-supplied names/emails
    const wrapper = document.createElement("div")
    wrapper.className = "collab-presence"

    const info = document.createElement("span")
    info.className = "collab-presence__info"

    const dot = document.createElement("span")
    dot.className = "collab-presence__dot"
    dot.setAttribute("aria-hidden", "true")
    info.appendChild(dot)
    info.append(` ${otherUsers.length} ${otherUsers.length === 1 ? "person" : "people"} editing`)
    wrapper.appendChild(info)

    const avatarsDiv = document.createElement("div")
    avatarsDiv.className = "collab-presence__avatars"

    otherUsers.forEach(user => {
      const displayName = user.name || user.email || ""
      const avatar = document.createElement("div")
      avatar.className = "collab-presence__avatar"
      avatar.title = displayName
      avatar.textContent = displayName.charAt(0).toUpperCase()
      avatarsDiv.appendChild(avatar)
    })

    wrapper.appendChild(avatarsDiv)
    this.presenceTarget.replaceChildren(wrapper)
  }

  updateConnectionStatus(connected) {
    // Could add a visual indicator for connection status
    if (connected) {
    } else {
      // Connection lost — UI could show a reconnecting indicator
    }
  }

  showNotification(message, type = "info") {
    // Create a simple toast notification
    const notification = document.createElement("div")
    notification.className = `toast toast--${type}`
    notification.textContent = message
    
    document.body.appendChild(notification)
    
    setTimeout(() => {
      notification.style.transition = "opacity 0.3s"
      notification.style.opacity = "0"
      setTimeout(() => notification.remove(), 300)
    }, 3000)
  }

  // Public method to check if remote change is being applied
  isApplyingRemoteChange() {
    return this.applyingRemoteChange
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}

