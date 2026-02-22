import { Controller } from "@hotwired/stimulus"
import { subscribeToWorkflow } from "../channels/workflow_channel"
import { renderIcon, UI_ICON_PATHS } from "../services/icon_service"

export default class extends Controller {
  static targets = ["status", "lockVersion", "conflictModal"]
  static values = { 
    workflowId: Number,
    debounceMs: { type: Number, default: 1000 },
    lockVersion: { type: Number, default: 0 }
  }

  connect() {
    // Find the form element (the controller is on the form itself)
    this.formElement = this.element.tagName === "FORM" ? this.element : this.element.closest("form")
    
    if (!this.formElement) {
      console.error("Autosave controller: Form element not found")
      return
    }

    // Initialize lock_version from the form's hidden field
    this.initializeLockVersion()

    // Subscribe to workflow channel if workflow ID is available
    if (this.hasWorkflowIdValue) {
      this.subscription = subscribeToWorkflow(this.workflowIdValue, {
        connected: () => {
          console.log("Autosave: Connected to workflow channel")
          this.handleConnected()
        },
        disconnected: () => {
          console.log("Autosave: Disconnected from workflow channel")
          this.handleDisconnected()
        },
        saved: (data) => {
          console.log("Autosave: Received saved callback", data)
          this.handleSaved(data)
        },
        error: (data) => {
          console.log("Autosave: Received error callback", data)
          this.handleError(data)
        },
        conflict: (data) => {
          console.log("Autosave: Received conflict callback", data)
          this.handleConflict(data)
        }
      })
      
      // Also listen for the custom event (backup)
      this.autosavedHandler = (event) => {
        console.log("Autosave: Received workflow:autosaved event", event.detail)
        if (event.detail.status === "saved") {
          this.handleSaved(event.detail)
        } else if (event.detail.status === "error") {
          this.handleError(event.detail)
        } else if (event.detail.status === "conflict") {
          this.handleConflict(event.detail)
        }
      }
      document.addEventListener("workflow:autosaved", this.autosavedHandler)
    }

    // Set up form change listeners
    this.debouncedAutosave = this.debounce(() => this.performAutosave(), this.debounceMsValue)
    
    // Store handlers so we can remove them later
    this.inputHandler = (event) => {
      // Skip autosave if this is a remote update from collaboration
      if (event.detail && event.detail.remoteUpdate) {
        return
      }
      this.debouncedAutosave()
    }
    
    this.changeHandler = (event) => {
      // Skip autosave if this is a remote update from collaboration
      if (event.detail && event.detail.remoteUpdate) {
        return
      }
      this.debouncedAutosave()
    }
    
    // Listen for form changes
    this.formElement.addEventListener("input", this.inputHandler)
    this.formElement.addEventListener("change", this.changeHandler)
    
    // Also listen for Trix changes
    this.formElement.addEventListener("trix-change", this.debouncedAutosave)
    
    // Initial status
    this.updateStatus("ready", "Ready to save")
  }

  initializeLockVersion() {
    // Try to get lock_version from hidden field in the form
    const lockVersionInput = this.formElement.querySelector("input[name='workflow[lock_version]']")
    if (lockVersionInput) {
      this.lockVersionValue = parseInt(lockVersionInput.value) || 0
    }
    console.log("Autosave: Initialized lock_version:", this.lockVersionValue)
  }

  updateLockVersion(newVersion) {
    this.lockVersionValue = newVersion
    
    // Update the hidden field in the form
    const lockVersionInput = this.formElement.querySelector("input[name='workflow[lock_version]']")
    if (lockVersionInput) {
      lockVersionInput.value = newVersion
    }
    
    console.log("Autosave: Updated lock_version to:", newVersion)
  }

  disconnect() {
    // Cleanup
    if (this.formElement) {
      if (this.inputHandler) {
        this.formElement.removeEventListener("input", this.inputHandler)
      }
      if (this.changeHandler) {
        this.formElement.removeEventListener("change", this.changeHandler)
      }
      this.formElement.removeEventListener("trix-change", this.debouncedAutosave)
    }
    
    // Remove event listener
    if (this.autosavedHandler) {
      document.removeEventListener("workflow:autosaved", this.autosavedHandler)
    }
    
    // Unsubscribe from channel
    if (this.subscription) {
      this.subscription.unsubscribe()
    }
  }

  performAutosave() {
    if (!this.hasWorkflowIdValue || !this.subscription) {
      console.warn("Cannot autosave: workflow ID or subscription missing")
      return
    }

    if (!this.formElement) {
      console.error("Cannot autosave: form element not found")
      return
    }

    // Don't autosave if there's an unresolved conflict
    if (this.hasConflict) {
      console.warn("Autosave: Skipping due to unresolved conflict")
      return
    }

    console.log("Autosave: Starting autosave...")
    this.updateStatus("saving", "Saving...")
    
    // Collect form data
    const formData = new FormData(this.formElement)
    const workflowData = this.extractWorkflowData(formData)
    
    // Debug logging
    console.log("Autosave: Sending data to server", {
      workflowId: this.workflowIdValue,
      lockVersion: workflowData.lock_version,
      title: workflowData.title,
      stepsCount: workflowData.steps.length
    })
    
    // Send to server via ActionCable
    this.subscription.autosave(workflowData)
  }

  extractWorkflowData(formData) {
    const data = {
      title: formData.get("workflow[title]") || "",
      description: formData.get("workflow[description]") || "",
      lock_version: this.lockVersionValue  // Include lock_version for optimistic locking
    }

    // Extract steps data - Rails uses array notation workflow[steps][]
    // We need to group fields by their position in the form
    const steps = []
    const stepContainers = this.formElement.querySelectorAll(".step-item")
    
    stepContainers.forEach((container, containerIndex) => {
      const step = {}
      
      // Get all inputs within this step container
      const inputs = container.querySelectorAll("input, textarea, select")
      inputs.forEach(input => {
        const name = input.name
        if (!name || !name.startsWith("workflow[steps]")) return
        
        // Handle nested fields like workflow[steps][][attachments] or workflow[steps][][options][][label]
        if (name.includes("[attachments]")) {
          // Parse JSON string for attachments
          try {
            step.attachments = JSON.parse(input.value || "[]")
          } catch (e) {
            step.attachments = []
          }
        } else if (name.includes("[options]")) {
          // Handle options array - collect from .option-item containers
          // Form uses empty-bracket notation ([][]) so we extract by DOM structure
          if (!step._optionsProcessed) {
            step._optionsProcessed = true
            step.options = []
            const optionItems = container.querySelectorAll('.option-item')
            optionItems.forEach(optItem => {
              const labelInput = optItem.querySelector('input[name*="[options]"][name*="[label]"]')
              const valueInput = optItem.querySelector('input[name*="[options]"][name*="[value]"]')
              if (labelInput || valueInput) {
                step.options.push({
                  label: labelInput?.value || '',
                  value: valueInput?.value || ''
                })
              }
            })
          }
        } else {
          // Regular field: workflow[steps][][field]
          const match = name.match(/workflow\[steps\]\[\]?\[(\w+)\]/)
          if (match) {
            const field = match[1]
            let value = input.value
            
            // Handle checkboxes
            if (input.type === "checkbox") {
              value = input.checked
            }
            
            // Skip if field already set (avoid overwriting)
            if (step[field] === undefined) {
              step[field] = value
            }
          }
        }
      })
      
      // Clean up options - remove empty ones
      if (step.options && Array.isArray(step.options)) {
        step.options = step.options.filter(opt => opt && (opt.label || opt.value))
      }
      
      // Clean up internal processing flags
      delete step._optionsProcessed

      // Only add step if it has at least a type
      if (step.type) {
        steps.push(step)
      }
    })

    data.steps = steps
    return data
  }

  handleConnected() {
    console.log("Connected to workflow channel")
    this.updateStatus("ready", "Connected - ready to save")
  }

  handleDisconnected() {
    console.log("Disconnected from workflow channel")
    this.updateStatus("error", "Disconnected")
  }

  handleSaved(data) {
    console.log("Autosave successful:", data)
    
    // Update lock_version from server response
    if (data.lock_version !== undefined) {
      this.updateLockVersion(data.lock_version)
    }
    
    // Clear any conflict state
    this.hasConflict = false
    
    const timestamp = data.timestamp ? new Date(data.timestamp).toLocaleTimeString() : new Date().toLocaleTimeString()
    const savedBy = data.saved_by ? ` by ${data.saved_by.name}` : ""
    this.updateStatus("saved", `Saved at ${timestamp}${savedBy}`)
    
    // Reset to ready after 3 seconds
    setTimeout(() => {
      if (this.hasStatusTarget && this.statusTarget.textContent.includes("Saved")) {
        this.updateStatus("ready", "Ready to save")
      }
    }, 3000)
  }

  handleError(data) {
    console.error("Autosave error:", data.errors)
    const errorMessage = data.errors && data.errors.length > 0 
      ? data.errors.join(", ") 
      : "Unknown error"
    this.updateStatus("error", `Error: ${errorMessage}`)
    
    // Reset to ready after 5 seconds
    setTimeout(() => {
      if (this.hasStatusTarget) {
        this.updateStatus("ready", "Ready to save")
      }
    }, 5000)
  }

  handleConflict(data) {
    console.warn("Autosave conflict detected:", data)
    
    // Mark that we have a conflict
    this.hasConflict = true
    
    // Store conflict data for potential resolution
    this.conflictData = {
      serverVersion: data.lock_version,
      serverTitle: data.server_title,
      serverSteps: data.server_steps,
      conflictUser: data.conflict_user,
      message: data.message
    }
    
    // Update status to show conflict
    const conflictUser = data.conflict_user ? data.conflict_user.name : "another user"
    this.updateConflictStatus(`Conflict: Modified by ${conflictUser}`)
    
    // Show conflict modal or alert
    this.showConflictNotification(data)
  }

  showConflictNotification(data) {
    const conflictUser = data.conflict_user ? data.conflict_user.name : "another user"
    const message = data.message || `This workflow was modified by ${conflictUser}. Please refresh to see the latest changes.`
    
    // Check if there's a conflict modal target
    if (this.hasConflictModalTarget) {
      // Update modal content
      const modalMessage = this.conflictModalTarget.querySelector("[data-conflict-message]")
      if (modalMessage) {
        modalMessage.textContent = message
      }
      
      const modalUser = this.conflictModalTarget.querySelector("[data-conflict-user]")
      if (modalUser) {
        modalUser.textContent = conflictUser
      }
      
      // Show the modal
      this.conflictModalTarget.classList.remove("hidden")
    } else {
      // Fallback to browser alert/confirm
      const shouldRefresh = confirm(
        `${message}\n\nWould you like to refresh the page to see the latest version?\n\n` +
        `Note: Your unsaved changes will be lost if you refresh.`
      )
      
      if (shouldRefresh) {
        window.location.reload()
      }
    }
  }

  resolveConflict(action) {
    if (action === "refresh") {
      // Reload the page to get the latest version
      window.location.reload()
    } else if (action === "force") {
      // Force save by updating lock_version and retrying
      if (this.conflictData && this.conflictData.serverVersion) {
        this.updateLockVersion(this.conflictData.serverVersion)
        this.hasConflict = false
        this.performAutosave()
      }
    } else if (action === "dismiss") {
      // Just dismiss the conflict notification (user will manually handle)
      this.hasConflict = false
      if (this.hasConflictModalTarget) {
        this.conflictModalTarget.classList.add("hidden")
      }
      this.updateStatus("ready", "Ready to save")
    }
  }

  // Action handlers for conflict modal buttons
  refreshPage() {
    this.resolveConflict("refresh")
  }

  forceSave() {
    this.resolveConflict("force")
  }

  dismissConflict() {
    this.resolveConflict("dismiss")
  }

  updateStatus(status, message) {
    if (!this.hasStatusTarget) return

    // Update status text
    this.statusTarget.textContent = message

    // Update status classes
    this.statusTarget.className = "text-sm font-medium "

    switch(status) {
      case "saving":
        this.statusTarget.className += "text-yellow-600"
        break
      case "saved":
        this.statusTarget.className += "text-green-600"
        break
      case "error":
        this.statusTarget.className += "text-red-600"
        break
      case "conflict":
        this.statusTarget.className += "text-red-600"
        break
      default:
        this.statusTarget.className += "text-gray-600"
    }
  }

  updateConflictStatus(message) {
    if (!this.hasStatusTarget) return

    this.statusTarget.className = "text-sm font-medium text-red-600 inline-flex items-center gap-1"
    this.statusTarget.innerHTML = `${renderIcon(UI_ICON_PATHS.warning, "w-4 h-4")} ${this.escapeHtml(message)}`
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }

  debounce(func, delay) {
    let timeout
    return function(...args) {
      const context = this
      clearTimeout(timeout)
      timeout = setTimeout(() => func.apply(context, args), delay)
    }
  }
}

