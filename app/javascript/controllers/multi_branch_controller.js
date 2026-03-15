import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["branchesContainer", "branchTemplate", "elsePathContainer"]
  static values = {
    workflowId: Number,
    variablesUrl: String
  }

  connect() {
    // Check if branches already exist (rendered by ERB)
    const existingBranches = this.branchesContainerTarget.querySelectorAll('.branch-item')

    if (existingBranches.length === 0) {
      // No branches exist, check for legacy format or add one empty branch
      this.initializeBranches()
    } else {
      // Branches already exist from ERB, initialize with retry pattern
      this.initializeExistingBranchesWithRetry(existingBranches)
    }
    
    // Listen for template-applied events
    this.handleTemplateApplied = this.handleTemplateApplied.bind(this)
    this.element.addEventListener('template-applied', this.handleTemplateApplied)

    // Set up listeners for workflow changes
    this.setupWorkflowChangeListener()
  }

  // Initialize with exponential backoff retry (100ms, 200ms, 400ms, 800ms, 1600ms)
  initializeExistingBranchesWithRetry(branchElements, attempt = 0) {
    const maxAttempts = 5
    const baseDelay = 100

    const allReady = this.tryInitializeBranches(branchElements)

    if (!allReady && attempt < maxAttempts) {
      setTimeout(() => {
        this.initializeExistingBranchesWithRetry(branchElements, attempt + 1)
      }, baseDelay * Math.pow(2, attempt))
    }
  }

  tryInitializeBranches(branchElements) {
    let allSucceeded = true

    branchElements.forEach((branchItem, index) => {
      if (!this.initializeBranchControllerSafe(index, 'rule-builder', 'refreshVariables')) {
        allSucceeded = false
      }
      if (!this.initializeBranchControllerSafe(index, 'step-selector', 'refresh')) {
        allSucceeded = false
      }
    })

    if (!this.initializeElsePathSafe()) {
      allSucceeded = false
    }

    return allSucceeded
  }

  initializeBranchControllerSafe(index, controllerName, methodName) {
    const branchItem = this.branchesContainerTarget.querySelector(`[data-branch-index="${index}"]`)
    if (!branchItem) return true // No branch is OK

    const element = branchItem.querySelector(`[data-controller*="${controllerName}"]`)
    if (!element) return true // No controller element is OK

    const application = window.Stimulus
    if (!application) return false

    try {
      const controller = application.getControllerForElementAndIdentifier(element, controllerName)
      if (controller && typeof controller[methodName] === 'function') {
        controller[methodName]()
        return true
      }
    } catch (e) {
      // Controller not ready yet
    }
    return false
  }

  initializeElsePathSafe() {
    if (!this.hasElsePathContainerTarget) return true

    const stepSelector = this.elsePathContainerTarget.querySelector('[data-controller*="step-selector"]')
    if (!stepSelector) return true

    const application = window.Stimulus
    if (!application) return false

    try {
      const controller = application.getControllerForElementAndIdentifier(stepSelector, "step-selector")
      if (controller && typeof controller.refresh === 'function') {
        controller.refresh()
        return true
      }
    } catch (e) {
      // Controller not ready yet
    }
    return false
  }
  
  handleTemplateApplied(event) {
    console.log('[Multi-Branch] Template-applied event received:', event.detail)
    
    const { branches } = event.detail
    
    if (!branches || branches.length === 0) {
      console.warn('[Multi-Branch] No branches in template-applied event')
      return
    }
    
    console.log('[Multi-Branch] Processing', branches.length, 'branches')
    
    // Clear existing branches
    if (this.hasBranchesContainerTarget) {
      this.branchesContainerTarget.innerHTML = ''
    }
    
    // Add branches from template with a slight delay to ensure DOM is ready
    branches.forEach((branch, index) => {
      setTimeout(() => {
        console.log(`[Multi-Branch] Adding branch ${index}:`, branch)
        this.addBranchDirect(branch.condition, branch.path)
      }, index * 100) // Stagger branch creation
    })
    
    // Refresh and notify after all branches are created
    setTimeout(() => {
      console.log('[Multi-Branch] Refreshing dropdowns and notifying')
      this.refreshAllBranchDropdowns()
      this.notifyBranchAssistant()
      this.notifyPreviewUpdate()
    }, branches.length * 100 + 100)
  }
  
  initializeElsePathStepSelector() {
    // Legacy method - now uses initializeElsePathSafe() with retry pattern
    // Kept for backward compatibility with addBranchDirect calls
    this.initializeElsePathSafe()
  }

  initializeBranches() {
    // Check for legacy true_path/false_path
    const truePath = this.getLegacyTruePath()
    const falsePath = this.getLegacyFalsePath()
    
    if (truePath || falsePath) {
      // Convert legacy format to branches
      // Note: We need to get the condition from the legacy condition input
      const stepItem = this.element.closest('.step-item')
      const conditionInput = stepItem?.querySelector('input[name*="[condition]"]')
      const condition = conditionInput ? conditionInput.value : ""
      
      if (truePath) {
        this.addBranchDirect(condition, truePath)
      }
      if (falsePath) {
        // For false path, we need to create a condition that's the opposite
        // For simplicity, we'll add it as-is and let the user edit it
        this.addBranchDirect("", falsePath)
      }
    } else {
      // Start with one empty branch
      this.addBranchDirect()
    }
  }

  addBranchDirect(condition = "", path = "") {
    if (!this.hasBranchesContainerTarget) return
    
    const branchIndex = this.branchesContainerTarget.querySelectorAll('.branch-item').length
    const branchHtml = this.createBranchHtml(branchIndex, condition, path)
    
    this.branchesContainerTarget.insertAdjacentHTML('beforeend', branchHtml)
    
    // Initialize rule builder for the new branch (with delay to ensure Stimulus connects)
    setTimeout(() => {
      this.initializeBranchRuleBuilder(branchIndex)
      
      if (condition) {
        // Parse condition to populate rule builder fields
        const branchItem = this.branchesContainerTarget.querySelector(`[data-branch-index="${branchIndex}"]`)
        if (branchItem) {
          const ruleBuilder = branchItem.querySelector('[data-controller*="rule-builder"]')
          if (ruleBuilder) {
            const application = window.Stimulus
            if (application) {
              try {
                const controller = application.getControllerForElementAndIdentifier(ruleBuilder, "rule-builder")
                if (controller && controller.parseExistingCondition) {
                  controller.parseExistingCondition()
                  if (controller.buildCondition) {
                    controller.buildCondition()
                  }
                }
              } catch (e) {
                // Rule builder will initialize automatically
              }
            }
          }
        }
      }
    }, 150)
    
    // Initialize step selector for the new branch
    this.initializeBranchStepSelector(branchIndex)
    
    // Update hidden inputs
    this.updateBranchesInputs()
    
    // Refresh dropdowns
    this.refreshAllBranchDropdowns()
  }

  getExistingBranches() {
    // Extract branches from hidden inputs
    const branches = []
    const stepItem = this.element.closest('.step-item')
    if (!stepItem) return branches
    
    const branchInputs = stepItem.querySelectorAll('input[name*="[branches]"][name*="[condition]"]')
    branchInputs.forEach(input => {
      const condition = input.value
      const pathInput = input.closest('.branch-item')?.querySelector('select[name*="[path]"]')
      const path = pathInput ? pathInput.value : ''
      
      if (condition || path) {
        branches.push({ condition, path })
      }
    })
    
    return branches
  }

  getLegacyTruePath() {
    const stepItem = this.element.closest('.step-item')
    if (!stepItem) return null
    
    const truePathInput = stepItem.querySelector('input[name*="[true_path]"]')
    return truePathInput ? truePathInput.value : null
  }

  getLegacyFalsePath() {
    const stepItem = this.element.closest('.step-item')
    if (!stepItem) return null
    
    const falsePathInput = stepItem.querySelector('input[name*="[false_path]"]')
    return falsePathInput ? falsePathInput.value : null
  }

  setupWorkflowChangeListener() {
    this.form = this.element.closest("form")
    if (this.form) {
      this.workflowChangeHandler = () => {
        // Refresh step options in all branch dropdowns
        this.refreshAllBranchDropdowns()
      }
      this.form.addEventListener("input", this.workflowChangeHandler)
      this.form.addEventListener("change", this.workflowChangeHandler)
    }
  }

  disconnect() {
    // Clean up template-applied event listener
    if (this.handleTemplateApplied) {
      this.element.removeEventListener('template-applied', this.handleTemplateApplied)
    }

    // Clean up form change listeners
    if (this.form && this.workflowChangeHandler) {
      this.form.removeEventListener("input", this.workflowChangeHandler)
      this.form.removeEventListener("change", this.workflowChangeHandler)
    }
  }

  addBranch(event) {
    // Handle both event-based calls and direct calls
    if (event && event.preventDefault) {
      event.preventDefault()
    }
    
    if (!this.hasBranchesContainerTarget) {
      console.error("Multi-branch controller: branchesContainer target not found")
      return
    }
    
    const branchIndex = this.branchesContainerTarget.querySelectorAll('.branch-item').length
    const branchHtml = this.createBranchHtml(branchIndex, "", "")
    
    this.branchesContainerTarget.insertAdjacentHTML('beforeend', branchHtml)
    
    // Initialize rule builder for the new branch
    this.initializeBranchRuleBuilder(branchIndex)
    
    // Initialize step selector for the new branch
    this.initializeBranchStepSelector(branchIndex)
    
    // Update hidden inputs
    this.updateBranchesInputs()
    
    // Refresh dropdowns
    this.refreshAllBranchDropdowns()
    
    // Notify preview update
    this.notifyPreviewUpdate()
  }
  
  initializeBranchStepSelector(index) {
    const branchItem = this.branchesContainerTarget.querySelector(`[data-branch-index="${index}"]`)
    if (!branchItem) return
    
    const stepSelector = branchItem.querySelector('[data-controller*="step-selector"]')
    if (!stepSelector) return
    
    // Use a delay to ensure Stimulus has connected the controller
    setTimeout(() => {
      const application = window.Stimulus
      if (application) {
        try {
          const controller = application.getControllerForElementAndIdentifier(stepSelector, "step-selector")
          if (controller && typeof controller.refresh === 'function') {
            controller.refresh()
          }
        } catch (e) {
          console.warn(`Error initializing step selector: ${e.message}`)
        }
      }
    }, 100)
  }

  createBranchHtml(index, condition, path) {
    // Note: stepOptions no longer needed - using step selector component instead
    
    return `
      <div class="branch-item" data-branch-index="${index}">
        <div class="branch-item__header">
          <span class="branch-item__label">Branch ${index + 1}</span>
          <button type="button" 
                  class="btn btn--negative btn--sm"
                  data-action="click->multi-branch#removeBranch"
                  data-branch-index="${index}">
            Remove
          </button>
        </div>
        
        <div class="branch-item__body">
          <div data-controller="rule-builder" 
               data-rule-builder-workflow-id-value="${this.workflowIdValue || ''}"
               data-rule-builder-variables-url-value="${this.variablesUrlValue || ''}">
            <label class="form-label">Condition</label>
            <input type="hidden" 
                   name="workflow[steps][][branches][][condition]" 
                   value="${this.escapeHtml(condition)}"
                   data-rule-builder-target="conditionInput"
                   data-step-form-target="field">
            
            <div class="branch-condition-grid">
              <div>
                <label class="form-label">Variable</label>
                <select data-rule-builder-target="variableSelect" 
                        class="form-select"
                        data-action="change->rule-builder#buildCondition">
                  <option value="">-- Select variable --</option>
                </select>
              </div>
              
              <div>
                <label class="form-label">Operator</label>
                <select data-rule-builder-target="operatorSelect" 
                        class="form-select"
                        data-action="change->rule-builder#buildCondition">
                  <option value="">-- Select --</option>
                  <option value="==" ${condition.includes('==') ? 'selected' : ''}>Equals (==)</option>
                  <option value="!=" ${condition.includes('!=') ? 'selected' : ''}>Not Equals (!=)</option>
                  <option value=">" ${condition.match(/\s>\s/) && !condition.match(/>\s*=/) ? 'selected' : ''}>Greater Than (>)</option>
                  <option value=">=" ${condition.includes('>=') ? 'selected' : ''}>Greater or Equal (>=)</option>
                  <option value="<" ${condition.match(/\s<\s/) && !condition.match(/<\s*=/) ? 'selected' : ''}>Less Than (<)</option>
                  <option value="<=" ${condition.includes('<=') ? 'selected' : ''}>Less or Equal (<=)</option>
                </select>
              </div>
              
              <div>
                <label class="form-label">Value</label>
                <input type="text" 
                       data-rule-builder-target="valueInput" 
                       placeholder="Value"
                       class="form-input"
                       data-action="input->rule-builder#buildCondition">
              </div>
            </div>
            
            <div class="condition-preview">
              <span class="condition-preview__label">Condition:</span>
              <span data-rule-builder-target="conditionDisplay">${condition || "Not set"}</span>
            </div>
          </div>
          
          <div>
            <label class="form-label">Go to:</label>
            <div data-controller="step-selector"
                 data-step-selector-selected-value-value="${path}"
                 data-step-selector-placeholder-value="-- Select step --"
                 class="step-selector">
              <input type="hidden" 
                     name="workflow[steps][][branches][][path]" 
                     value="${this.escapeHtml(path)}"
                     data-step-selector-target="hiddenInput"
                     data-step-form-target="field"
                     data-multi-branch-target="branchPathSelect">
              <button type="button"
                      class="step-selector__button"
                      data-step-selector-target="button"
                      data-action="click->step-selector#toggle">
                <span class="step-selector__placeholder">-- Select step --</span>
              </button>
              <div class="step-selector__dropdown is-hidden"
                   data-step-selector-target="dropdown">
                <div class="step-selector__search-wrap">
                  <input type="text"
                         placeholder="Search steps..."
                         class="form-input"
                         data-step-selector-target="search"
                         data-action="input->step-selector#search">
                </div>
                <div class="step-selector__options" data-step-selector-target="options">
                  <!-- Options will be rendered here -->
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    `
  }

  initializeBranchRuleBuilder(index) {
    const branchItem = this.branchesContainerTarget.querySelector(`[data-branch-index="${index}"]`)
    if (!branchItem) return
    
    const ruleBuilder = branchItem.querySelector('[data-controller*="rule-builder"]')
    if (!ruleBuilder) {
      // Rule builder will initialize automatically via Stimulus
      return
    }
    
    // The rule builder should initialize itself via Stimulus
    // Just dispatch a refresh event to ensure it refreshes variables
    // Use a delay to ensure Stimulus has connected the controller
    setTimeout(() => {
      ruleBuilder.dispatchEvent(new CustomEvent('refresh-variables'))
      
      // Also try to get the controller directly (for debugging)
      const application = window.Stimulus
      if (application) {
        try {
          const controller = application.getControllerForElementAndIdentifier(ruleBuilder, "rule-builder")
          if (controller) {
            if (typeof controller.refreshVariables === 'function') {
              controller.refreshVariables()
            }
          }
        } catch (e) {
          // Rule builder will initialize automatically via Stimulus
        }
      }
    }, 500)
  }

  removeBranch(event) {
    const branchIndex = event.currentTarget.dataset.branchIndex
    const branchItem = this.branchesContainerTarget.querySelector(`[data-branch-index="${branchIndex}"]`)
    
    if (branchItem) {
      branchItem.remove()
      this.updateBranchesInputs()
      this.refreshAllBranchDropdowns()
      this.notifyPreviewUpdate()
    }
  }

  updateBranchesInputs() {
    // Update branch indices
    const branchItems = this.branchesContainerTarget.querySelectorAll('.branch-item')
    branchItems.forEach((item, index) => {
      item.setAttribute('data-branch-index', index)
      const header = item.querySelector('.text-sm.font-medium')
      if (header) {
        header.textContent = `Branch ${index + 1}`
      }
    })
  }

  refreshAllBranchDropdowns() {
    // Refresh all step selector controllers instead of updating select dropdowns
    const stepSelectors = this.element.querySelectorAll('[data-controller*="step-selector"]')
    if (stepSelectors && stepSelectors.length > 0) {
      stepSelectors.forEach(element => {
        const application = window.Stimulus
        if (application && element) {
          try {
            const controller = application.getControllerForElementAndIdentifier(element, "step-selector")
            if (controller && typeof controller.refresh === 'function') {
              controller.refresh()
            }
          } catch (e) {
            // Controller might not be connected yet, that's okay
            // Step selector not yet connected, will retry on next refresh
          }
        }
      })
    }
  }

  getAvailableSteps() {
    const steps = []
    const workflowBuilder = document.querySelector("[data-controller*='workflow-builder']")
    const stepItems = workflowBuilder 
      ? workflowBuilder.querySelectorAll(".step-item")
      : document.querySelectorAll(".step-item")
    
    stepItems.forEach(stepItem => {
      const typeInput = stepItem.querySelector("input[name*='[type]']")
      const titleInput = stepItem.querySelector("input[name*='[title]']")
      const currentStepItem = this.element.closest('.step-item')
      
      if (typeInput && titleInput && stepItem !== currentStepItem) {
        const title = titleInput.value.trim()
        if (title) {
          steps.push({ title })
        }
      }
    })
    
    return steps
  }

  notifyPreviewUpdate() {
    // Dispatch event for preview updater
    this.element.dispatchEvent(new CustomEvent("workflow-steps-changed", { bubbles: true }))
    
    // Also trigger workflow builder update
    const workflowBuilder = document.querySelector("[data-controller*='workflow-builder']")
    if (workflowBuilder) {
      workflowBuilder.dispatchEvent(new CustomEvent("workflow:updated"))
    }
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}

