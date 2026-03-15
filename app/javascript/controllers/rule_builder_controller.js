import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "variableSelect",
    "operatorSelect",
    "valueInput",
    "conditionInput",
    "conditionDisplay",
    "presetButtons",
    "validationMessage",
    "helpText",
    "valueSuggestions"
  ]
  static values = {
    workflowId: Number,
    variablesUrl: String
  }

  connect() {
    // Parse existing condition if present
    this.parseExistingCondition()
    
    // Build condition when any field changes
    this.setupListeners()
    
    // Load variables from form and API
    // Use a small delay to ensure DOM is ready
    setTimeout(() => {
      this.refreshVariables()
    }, 100)
    
    // Listen for workflow changes to update variables
    this.setupWorkflowChangeListener()
    
    // Also listen for custom event to refresh variables
    this.element.addEventListener('refresh-variables', () => {
      this.refreshVariables()
    })
    
    // Initialize variable type detection
    this.detectVariableType()
    
    // Update UI based on variable type
    this.updateOperatorOptions()
    
    // Setup preset buttons
    this.setupPresetButtons()
  }

  disconnect() {
    // Cleanup listeners
    this.removeListeners()
    this.removeWorkflowChangeListener()

    // Cleanup variable type change listener
    if (this.boundVariableTypeChange && this.hasVariableSelectTarget) {
      this.variableSelectTarget.removeEventListener('change', this.boundVariableTypeChange)
    }
  }

  setupWorkflowChangeListener() {
    // Listen for changes in question steps that might affect variables
    // ONLY refresh when variable_name inputs change (not every input!)
    const form = this.element.closest("form")
    if (!form) return
    
    this.refreshDebounceTimer = null
    
    this.workflowChangeHandler = (event) => {
      // Only react to variable_name changes (not every input)
      if (!event.target.matches || !event.target.matches("input[name*='[variable_name]']")) {
        return
      }
      
      // Debounce heavily - 500ms delay
      if (this.refreshDebounceTimer) {
        clearTimeout(this.refreshDebounceTimer)
      }
      
      this.refreshDebounceTimer = setTimeout(() => {
        this.refreshVariables()
      }, 500)
    }
    
    form.addEventListener("input", this.workflowChangeHandler)
    
    // Also listen for step add/remove events
    this.boundStepChangeHandler = () => {
      if (this.refreshDebounceTimer) {
        clearTimeout(this.refreshDebounceTimer)
      }
      this.refreshDebounceTimer = setTimeout(() => {
        this.refreshVariables()
      }, 300)
    }
    document.addEventListener("workflow-builder:step-added", this.boundStepChangeHandler)
    document.addEventListener("workflow-builder:step-removed", this.boundStepChangeHandler)
  }

  removeWorkflowChangeListener() {
    const form = this.element.closest("form")
    if (form && this.workflowChangeHandler) {
      form.removeEventListener("input", this.workflowChangeHandler)
    }
    if (this.boundStepChangeHandler) {
      document.removeEventListener("workflow-builder:step-added", this.boundStepChangeHandler)
      document.removeEventListener("workflow-builder:step-removed", this.boundStepChangeHandler)
    }
    if (this.refreshDebounceTimer) {
      clearTimeout(this.refreshDebounceTimer)
    }
  }

  refreshVariables() {
    // Extract variables from form first (includes unsaved steps)
    const formVariables = this.extractVariablesFromForm()
    
    // Also try to load from API if available
    if (this.hasVariablesUrlValue && this.variablesUrlValue) {
      this.loadVariables().then(apiVariables => {
        // Merge form variables with API variables (form takes precedence)
        const allVariables = [...new Set([...formVariables, ...apiVariables])]
        this.populateVariableDropdown(allVariables)
      }).catch(error => {
        // Fallback to form variables only
        this.populateVariableDropdown(formVariables)
      })
    } else {
      // Just use form variables
      this.populateVariableDropdown(formVariables)
    }
  }

  extractVariablesFromForm() {
    const variables = []
    const form = this.element.closest("form")
    if (!form) {
      return variables
    }
    
    // Find all question step items
    const stepItems = form.querySelectorAll(".step-item")
    
    stepItems.forEach((stepItem, index) => {
      // Check if this is a question step
      const typeInput = stepItem.querySelector("input[name*='[type]']")
      if (!typeInput || typeInput.value !== "question") return
      
      // Find variable name input
      const variableInput = stepItem.querySelector("input[name*='[variable_name]']")
      if (variableInput && variableInput.value.trim()) {
        const variableName = variableInput.value.trim()
        if (variableName && !variables.includes(variableName)) {
          variables.push(variableName)
        }
      }
    })
    
    return variables.sort()
  }

  populateVariableDropdown(variables) {
    if (!this.hasVariableSelectTarget) {
      return
    }
    
    // Store current selection
    const currentValue = this.variableSelectTarget.value
    
    // Get existing options (server-rendered ones)
    const existingOptions = Array.from(this.variableSelectTarget.options)
      .map(opt => ({ value: opt.value, text: opt.text }))
      .filter(opt => opt.value !== "") // Exclude placeholder
    
    // Merge with new variables (avoid duplicates)
    const allVariableValues = [...new Set([...existingOptions.map(o => o.value), ...variables])]
    
    // Only update if we have new variables or if existing options are empty
    if (variables.length > 0 || existingOptions.length === 0) {
      // Clear existing options (except the first placeholder)
      const placeholder = this.variableSelectTarget.querySelector('option[value=""]')
      this.variableSelectTarget.innerHTML = ""
      if (placeholder) {
        this.variableSelectTarget.appendChild(placeholder)
      }
      
      // Add all variables (from both server-rendered and dynamically found)
      allVariableValues.forEach(variable => {
        const option = document.createElement('option')
        option.value = variable
        option.textContent = variable
        this.variableSelectTarget.appendChild(option)
      })
    }
    
    // Restore selection if still valid
    if (currentValue && allVariableValues.includes(currentValue)) {
      this.variableSelectTarget.value = currentValue
    } else if (allVariableValues.length > 0) {
      // If we have variables but no selection, try to parse condition
      this.parseExistingCondition()
    }
  }

  setupListeners() {
    // Store bound handlers to enable proper cleanup
    this.boundBuildCondition = () => this.buildCondition()
    this.variableSelectTarget?.addEventListener("change", this.boundBuildCondition)
    this.operatorSelectTarget?.addEventListener("change", this.boundBuildCondition)
    this.valueInputTarget?.addEventListener("input", this.boundBuildCondition)
  }

  removeListeners() {
    if (this.boundBuildCondition) {
      this.variableSelectTarget?.removeEventListener("change", this.boundBuildCondition)
      this.operatorSelectTarget?.removeEventListener("change", this.boundBuildCondition)
      this.valueInputTarget?.removeEventListener("input", this.boundBuildCondition)
    }
  }

  parseExistingCondition() {
    if (!this.hasConditionInputTarget) return
    
    const condition = this.conditionInputTarget.value
    if (!condition || condition.trim() === "") return
    
    // Parse condition like "variable == 'value'" or "variable != 'value'"
    // Support: ==, !=, >, <, >=, <=
    const patterns = [
      /^(\w+)\s*(==|!=)\s*['"]([^'"]*)['"]$/,  // variable == 'value'
      /^(\w+)\s*(>|>=|<|<=)\s*(\d+)$/          // variable > 10
    ]
    
    for (const pattern of patterns) {
      const match = condition.match(pattern)
      if (match) {
        const variable = match[1]
        const operator = match[2]
        const value = match[3] || ""
        
        // Set dropdowns/input
        if (this.hasVariableSelectTarget) {
          this.variableSelectTarget.value = variable
        }
        if (this.hasOperatorSelectTarget) {
          this.operatorSelectTarget.value = operator
        }
        if (this.hasValueInputTarget) {
          this.valueInputTarget.value = value
        }
        
        return
      }
    }
  }

  buildCondition() {
    if (!this.hasConditionInputTarget) return
    
    const variable = this.variableSelectTarget?.value || ""
    const operator = this.operatorSelectTarget?.value || ""
    const value = this.valueInputTarget?.value || ""
    
    if (!variable || !operator) {
      this.conditionInputTarget.value = ""
      if (this.hasConditionDisplayTarget) {
        this.conditionDisplayTarget.textContent = "Not set"
        this.conditionDisplayTarget.className = "condition-display is-empty"
      }
      this.updateValidation("")
      return
    }
    
    // Validate condition
    const validation = this.validateCondition(variable, operator, value)
    this.updateValidation(validation)
    
    // Build condition string based on operator type
    let condition = ""
    const varType = this.getVariableType(variable)
    
    if (operator === "==" || operator === "!=") {
      // String operators need quotes
      condition = `${variable} ${operator} '${value}'`
    } else {
      // Numeric operators (>, <, >=, <=)
      if (varType === 'numeric' && value && !isNaN(value)) {
        condition = `${variable} ${operator} ${value}`
      } else if (varType === 'numeric' && !value) {
        // Invalid: numeric operator without value
        condition = ""
      } else {
        // Treat as string comparison
        condition = `${variable} ${operator} '${value}'`
      }
    }
    
    this.conditionInputTarget.value = condition
    
    // Update display with formatted condition
    if (this.hasConditionDisplayTarget) {
      this.conditionDisplayTarget.textContent = condition || "Not set"
      this.conditionDisplayTarget.className = condition
        ? "condition-display"
        : "condition-display is-empty"
    }
    
    // Trigger input event for preview updater
    this.conditionInputTarget.dispatchEvent(new Event("input", { bubbles: true }))
  }
  
  validateCondition(variable, operator, value) {
    if (!variable) return { valid: false, message: "Please select a variable" }
    if (!operator) return { valid: false, message: "Please select an operator" }
    
    const varType = this.getVariableType(variable)
    
    // Check if numeric operators have numeric values
    if (['>', '<', '>=', '<='].includes(operator)) {
      if (!value) {
        return { valid: false, message: "Please enter a value" }
      }
      if (varType === 'numeric' && isNaN(value)) {
        return { valid: false, message: "Value must be a number" }
      }
    }
    
    // Check if string operators have values
    if (['==', '!='].includes(operator) && !value) {
      return { valid: false, message: "Please enter a value" }
    }
    
    return { valid: true, message: "" }
  }
  
  updateValidation(validation) {
    if (!this.hasValidationMessageTarget) return
    
    if (!validation || !validation.message) {
      this.validationMessageTarget.textContent = ""
      this.validationMessageTarget.className = "is-hidden"
      return
    }
    
    this.validationMessageTarget.textContent = validation.message
    this.validationMessageTarget.className = validation.valid
      ? "validation-message status--success"
      : "validation-message status--error"
  }
  
  getVariableType(variable) {
    if (!variable) return 'string'
    
    // Try to find the question step for this variable
    const form = this.element.closest("form")
    if (!form) return 'string'
    
    const stepItems = form.querySelectorAll(".step-item")
    for (const stepItem of stepItems) {
      const typeInput = stepItem.querySelector("input[name*='[type]']")
      if (!typeInput || typeInput.value !== "question") continue
      
      const variableInput = stepItem.querySelector("input[name*='[variable_name]']")
      const variableName = variableInput ? variableInput.value.trim() : ""
      
      if (variableName === variable) {
        // Check answer type
        let answerTypeInput = stepItem.querySelector("input[name*='[answer_type]'][type='hidden']")
        if (!answerTypeInput || !answerTypeInput.value) {
          answerTypeInput = stepItem.querySelector("input[name*='[answer_type]']:checked")
        }
        if (!answerTypeInput || !answerTypeInput.value) {
          answerTypeInput = stepItem.querySelector("input[name*='[answer_type]']")
        }
        
        const answerType = answerTypeInput ? answerTypeInput.value : ""
        
        if (answerType === 'number') {
          return 'numeric'
        }
        return 'string'
      }
    }
    
    return 'string' // Default to string
  }
  
  detectVariableType() {
    // This will be called when variable changes
    if (this.hasVariableSelectTarget) {
      // Store bound handler for cleanup
      this.boundVariableTypeChange = () => {
        this.updateOperatorOptions()
        this.updateValueSuggestions()
      }
      this.variableSelectTarget.addEventListener('change', this.boundVariableTypeChange)
    }
  }
  
  updateOperatorOptions() {
    if (!this.hasOperatorSelectTarget || !this.hasVariableSelectTarget) return
    
    const variable = this.variableSelectTarget.value
    const varType = this.getVariableType(variable)
    const currentOperator = this.operatorSelectTarget.value
    
    // Store current selection
    const currentValue = this.operatorSelectTarget.value
    
    // Update operator options based on variable type
    const stringOperators = [
      { value: "==", label: "Equals (==)" },
      { value: "!=", label: "Not Equals (!=)" }
    ]
    
    const numericOperators = [
      { value: "==", label: "Equals (==)" },
      { value: "!=", label: "Not Equals (!=)" },
      { value: ">", label: "Greater Than (>)" },
      { value: ">=", label: "Greater or Equal (>=)" },
      { value: "<", label: "Less Than (<)" },
      { value: "<=", label: "Less or Equal (<=)" }
    ]
    
    const operators = varType === 'numeric' ? numericOperators : stringOperators
    
    // Clear and repopulate
    this.operatorSelectTarget.innerHTML = '<option value="">-- Select --</option>'
    operators.forEach(op => {
      const option = document.createElement('option')
      option.value = op.value
      option.textContent = op.label
      this.operatorSelectTarget.appendChild(option)
    })
    
    // Restore selection if still valid
    if (currentValue && operators.some(op => op.value === currentValue)) {
      this.operatorSelectTarget.value = currentValue
    }
  }
  
  updateValueSuggestions() {
    if (!this.hasValueInputTarget || !this.hasVariableSelectTarget) return
    
    const variable = this.variableSelectTarget.value
    if (!variable) return
    
    // Find question step options for this variable
    const form = this.element.closest("form")
    if (!form) return
    
    const stepItems = form.querySelectorAll(".step-item")
    for (const stepItem of stepItems) {
      const typeInput = stepItem.querySelector("input[name*='[type]']")
      if (!typeInput || typeInput.value !== "question") continue
      
      const variableInput = stepItem.querySelector("input[name*='[variable_name]']")
      const variableName = variableInput ? variableInput.value.trim() : ""
      
      if (variableName === variable) {
        // Check if it's multiple choice or dropdown
        let answerTypeInput = stepItem.querySelector("input[name*='[answer_type]'][type='hidden']")
        if (!answerTypeInput || !answerTypeInput.value) {
          answerTypeInput = stepItem.querySelector("input[name*='[answer_type]']:checked")
        }
        if (!answerTypeInput || !answerTypeInput.value) {
          answerTypeInput = stepItem.querySelector("input[name*='[answer_type]']")
        }
        
        const answerType = answerTypeInput ? answerTypeInput.value : ""
        
        if (answerType === 'multiple_choice' || answerType === 'dropdown') {
          // Get options
          const optionInputs = stepItem.querySelectorAll("input[name*='[options]'][name*='[label]']")
          const options = Array.from(optionInputs).map(input => {
            const valueInput = input.closest('.option-item')?.querySelector("input[name*='[value]']")
            return {
              label: input.value,
              value: valueInput ? valueInput.value : input.value
            }
          }).filter(opt => opt.label || opt.value)
          
          // Create datalist for autocomplete
          if (options.length > 0 && this.hasValueSuggestionsTarget) {
            this.valueSuggestionsTarget.innerHTML = ""
            options.forEach(opt => {
              const option = document.createElement('option')
              option.value = opt.value || opt.label
              this.valueSuggestionsTarget.appendChild(option)
            })
            this.valueInputTarget.setAttribute('list', 'value-suggestions')
          }
        }
        break
      }
    }
  }
  
  setupPresetButtons() {
    // Preset buttons will be handled in the template
    // This method can be used to add click handlers if needed
  }
  
  applyPreset(event) {
    const preset = event.currentTarget.dataset.preset
    const variable = this.variableSelectTarget?.value || ""
    
    if (!variable) {
      this.updateValidation({ valid: false, message: "Please select a variable first" })
      return
    }
    
    switch (preset) {
      case 'equals':
        if (this.hasOperatorSelectTarget) this.operatorSelectTarget.value = "=="
        break
      case 'not_equals':
        if (this.hasOperatorSelectTarget) this.operatorSelectTarget.value = "!="
        break
      case 'greater_than':
        if (this.hasOperatorSelectTarget) this.operatorSelectTarget.value = ">"
        break
      case 'less_than':
        if (this.hasOperatorSelectTarget) this.operatorSelectTarget.value = "<"
        break
      case 'is_empty':
        if (this.hasOperatorSelectTarget) this.operatorSelectTarget.value = "=="
        if (this.hasValueInputTarget) this.valueInputTarget.value = ""
        break
      case 'is_not_empty':
        if (this.hasOperatorSelectTarget) this.operatorSelectTarget.value = "!="
        if (this.hasValueInputTarget) this.valueInputTarget.value = ""
        break
    }
    
    this.buildCondition()
  }

  async loadVariables() {
    if (!this.hasVariablesUrlValue || !this.variablesUrlValue) return []
    
    try {
      const response = await fetch(this.variablesUrlValue)
      if (!response.ok) return []
      
      const data = await response.json()
      return data.variables || []
    } catch (error) {
      console.error("Failed to load variables:", error)
      return []
    }
  }
}

