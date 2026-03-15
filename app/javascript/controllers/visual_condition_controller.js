import { Controller } from "@hotwired/stimulus"

/**
 * Visual Condition Controller
 * 
 * Provides a user-friendly, dropdown-based condition builder for non-technical users.
 * Replaces syntax-based input (variable == 'value') with sentence-style dropdowns:
 * "When [variable] [is/is not] [value]"
 */
export default class extends Controller {
  static targets = [
    "variableSelect",
    "operatorSelect", 
    "valueSelect",
    "valueInput",
    "valueContainer",
    "hiddenCondition",
    "conditionPreview",
    "helpText"
  ]
  
  static values = {
    workflowId: Number,
    condition: String
  }

  connect() {
    // Load variables from the form
    this.loadVariablesFromForm()
    
    // Parse existing condition if present
    if (this.conditionValue) {
      this.parseExistingCondition(this.conditionValue)
    } else if (this.hasHiddenConditionTarget && this.hiddenConditionTarget.value) {
      this.parseExistingCondition(this.hiddenConditionTarget.value)
    }
    
    // Listen for form changes to update variables
    this.setupFormChangeListener()
    
    // Update the condition preview
    this.updatePreview()
  }

  disconnect() {
    this.removeFormChangeListener()
  }

  /**
   * Load variables from question steps in the current form
   */
  loadVariablesFromForm() {
    if (!this.hasVariableSelectTarget) return
    
    const variables = this.extractVariablesWithMetadata()
    const currentValue = this.variableSelectTarget.value
    
    // Clear existing options except placeholder
    this.variableSelectTarget.innerHTML = '<option value="">Select a variable...</option>'
    
    // Add variables with friendly labels
    variables.forEach(variable => {
      const option = document.createElement('option')
      option.value = variable.name
      option.textContent = variable.displayName
      option.dataset.answerType = variable.answerType
      option.dataset.options = JSON.stringify(variable.options || [])
      this.variableSelectTarget.appendChild(option)
    })
    
    // Restore selection if valid
    if (currentValue) {
      const exists = variables.some(v => v.name === currentValue)
      if (exists) {
        this.variableSelectTarget.value = currentValue
        this.handleVariableChange()
      }
    }
  }

  /**
   * Extract variables with their metadata (answer type, options) from form
   */
  extractVariablesWithMetadata() {
    const variables = []
    const form = this.element.closest("form")
    if (!form) return variables
    
    const stepItems = form.querySelectorAll(".step-item")
    
    stepItems.forEach((stepItem) => {
      const typeInput = stepItem.querySelector("input[name*='[type]']")
      if (!typeInput || typeInput.value !== "question") return
      
      // Get variable name
      const variableInput = stepItem.querySelector("input[name*='[variable_name]']")
      const variableName = variableInput?.value?.trim()
      if (!variableName) return
      
      // Get step title for display
      const titleInput = stepItem.querySelector("input[name*='[title]']")
      const stepTitle = titleInput?.value?.trim() || variableName
      
      // Get answer type
      let answerType = ''
      const hiddenAnswerType = stepItem.querySelector("input[name*='[answer_type]'][type='hidden']")
      const checkedAnswerType = stepItem.querySelector("input[name*='[answer_type]']:checked")
      answerType = hiddenAnswerType?.value || checkedAnswerType?.value || ''
      
      // Get options for multiple choice/dropdown
      const options = []
      if (answerType === 'multiple_choice' || answerType === 'dropdown') {
        const optionItems = stepItem.querySelectorAll(".option-item")
        optionItems.forEach(item => {
          const labelInput = item.querySelector("input[name*='[label]']")
          const valueInput = item.querySelector("input[name*='[value]']")
          if (labelInput?.value || valueInput?.value) {
            options.push({
              label: labelInput?.value || valueInput?.value,
              value: valueInput?.value || labelInput?.value
            })
          }
        })
      }
      
      variables.push({
        name: variableName,
        displayName: `${stepTitle} (${variableName})`,
        answerType: answerType,
        options: options
      })
    })
    
    return variables
  }

  /**
   * Handle variable selection change
   */
  handleVariableChange() {
    if (!this.hasVariableSelectTarget) return
    
    const selectedOption = this.variableSelectTarget.selectedOptions[0]
    if (!selectedOption || !selectedOption.value) {
      this.showTextInput()
      this.updateCondition()
      return
    }
    
    const answerType = selectedOption.dataset.answerType
    const options = JSON.parse(selectedOption.dataset.options || '[]')
    
    // Update operator options based on answer type
    this.updateOperatorOptions(answerType)
    
    // Update value input based on answer type
    if (answerType === 'yes_no') {
      this.showSelectInput([
        { label: 'Yes', value: 'yes' },
        { label: 'No', value: 'no' }
      ])
    } else if ((answerType === 'multiple_choice' || answerType === 'dropdown') && options.length > 0) {
      this.showSelectInput(options)
    } else if (answerType === 'number') {
      this.showTextInput('number')
    } else {
      this.showTextInput('text')
    }
    
    this.updateCondition()
  }

  /**
   * Update operator dropdown based on variable type
   */
  updateOperatorOptions(answerType) {
    if (!this.hasOperatorSelectTarget) return
    
    const currentValue = this.operatorSelectTarget.value
    
    // Define operators with friendly labels
    const stringOperators = [
      { value: '==', label: 'is' },
      { value: '!=', label: 'is not' }
    ]
    
    const numericOperators = [
      { value: '==', label: 'equals' },
      { value: '!=', label: 'does not equal' },
      { value: '>', label: 'is greater than' },
      { value: '>=', label: 'is at least' },
      { value: '<', label: 'is less than' },
      { value: '<=', label: 'is at most' }
    ]
    
    const operators = answerType === 'number' ? numericOperators : stringOperators
    
    // Rebuild dropdown
    this.operatorSelectTarget.innerHTML = ''
    operators.forEach(op => {
      const option = document.createElement('option')
      option.value = op.value
      option.textContent = op.label
      this.operatorSelectTarget.appendChild(option)
    })
    
    // Restore selection if valid, otherwise default to first
    const validOperator = operators.some(op => op.value === currentValue)
    this.operatorSelectTarget.value = validOperator ? currentValue : operators[0].value
  }

  /**
   * Show dropdown select for value (yes/no, multiple choice)
   */
  showSelectInput(options) {
    if (!this.hasValueContainerTarget) return
    
    const currentValue = this.hasValueSelectTarget ? this.valueSelectTarget.value : 
                         this.hasValueInputTarget ? this.valueInputTarget.value : ''
    
    // Create select element
    const select = document.createElement('select')
    select.className = 'form-select'
    select.dataset.visualConditionTarget = 'valueSelect'
    select.dataset.action = 'change->visual-condition#updateCondition'
    
    // Add options
    options.forEach(opt => {
      const option = document.createElement('option')
      option.value = opt.value
      option.textContent = opt.label
      select.appendChild(option)
    })
    
    // Replace content
    this.valueContainerTarget.innerHTML = ''
    this.valueContainerTarget.appendChild(select)
    
    // Restore selection if valid
    const validValue = options.some(opt => opt.value === currentValue)
    if (validValue) {
      select.value = currentValue
    }
  }

  /**
   * Show text input for value (text, number)
   */
  showTextInput(type = 'text') {
    if (!this.hasValueContainerTarget) return
    
    const currentValue = this.hasValueSelectTarget ? this.valueSelectTarget.value :
                         this.hasValueInputTarget ? this.valueInputTarget.value : ''
    
    // Create input element
    const input = document.createElement('input')
    input.type = type
    input.className = 'form-input'
    input.placeholder = type === 'number' ? 'Enter a number...' : 'Enter a value...'
    input.dataset.visualConditionTarget = 'valueInput'
    input.dataset.action = 'input->visual-condition#updateCondition'
    input.value = currentValue
    
    // Replace content
    this.valueContainerTarget.innerHTML = ''
    this.valueContainerTarget.appendChild(input)
  }

  /**
   * Build and update the condition string
   */
  updateCondition() {
    const variable = this.hasVariableSelectTarget ? this.variableSelectTarget.value : ''
    const operator = this.hasOperatorSelectTarget ? this.operatorSelectTarget.value : '=='
    
    // Get value from either select or input
    let value = ''
    const valueSelect = this.element.querySelector('[data-visual-condition-target="valueSelect"]')
    const valueInput = this.element.querySelector('[data-visual-condition-target="valueInput"]')
    
    if (valueSelect) {
      value = valueSelect.value
    } else if (valueInput) {
      value = valueInput.value
    }
    
    // Build condition string
    let condition = ''
    if (variable && value !== '') {
      if (['>', '>=', '<', '<='].includes(operator) && !isNaN(value)) {
        // Numeric comparison
        condition = `${variable} ${operator} ${value}`
      } else {
        // String comparison with quotes
        condition = `${variable} ${operator} '${value}'`
      }
    }
    
    // Update hidden input
    if (this.hasHiddenConditionTarget) {
      this.hiddenConditionTarget.value = condition
      this.hiddenConditionTarget.dispatchEvent(new Event('input', { bubbles: true }))
      this.hiddenConditionTarget.dispatchEvent(new Event('change', { bubbles: true }))
    }
    
    // Update preview
    this.updatePreview()
  }

  /**
   * Update the human-readable condition preview
   */
  updatePreview() {
    if (!this.hasConditionPreviewTarget) return
    
    const variable = this.hasVariableSelectTarget ? this.variableSelectTarget.value : ''
    const operatorSelect = this.operatorSelectTarget
    const operatorLabel = operatorSelect?.selectedOptions[0]?.textContent || ''
    
    // Get value and its display label
    let valueDisplay = ''
    const valueSelect = this.element.querySelector('[data-visual-condition-target="valueSelect"]')
    const valueInput = this.element.querySelector('[data-visual-condition-target="valueInput"]')
    
    if (valueSelect && valueSelect.value) {
      valueDisplay = valueSelect.selectedOptions[0]?.textContent || valueSelect.value
    } else if (valueInput && valueInput.value) {
      valueDisplay = valueInput.value
    }
    
    // Get variable display name
    let variableDisplay = variable
    if (this.hasVariableSelectTarget && this.variableSelectTarget.selectedOptions[0]) {
      const fullDisplay = this.variableSelectTarget.selectedOptions[0].textContent
      // Extract just the variable name without the full display
      variableDisplay = variable || 'variable'
    }
    
    if (variable && valueDisplay) {
      this.conditionPreviewTarget.innerHTML = `
        <span class="condition-token condition-token--variable">${this.escapeHtml(variableDisplay)}</span>
        <span class="condition-token condition-token--operator">${this.escapeHtml(operatorLabel)}</span>
        <span class="condition-token condition-token--value">"${this.escapeHtml(valueDisplay)}"</span>
      `
      this.conditionPreviewTarget.classList.remove('is-empty')
    } else {
      this.conditionPreviewTarget.textContent = 'Select a variable and value to create a condition'
      this.conditionPreviewTarget.classList.add('is-empty')
    }
  }

  /**
   * Parse an existing condition string and set the dropdowns
   */
  parseExistingCondition(condition) {
    if (!condition) return
    
    // Pattern for string conditions: variable == 'value' or variable != 'value'
    const stringPattern = /^(\w+)\s*(==|!=)\s*['"]([^'"]*)['"]\s*$/
    // Pattern for numeric conditions: variable > 10
    const numericPattern = /^(\w+)\s*(==|!=|>|>=|<|<=)\s*(\d+)\s*$/
    
    let variable, operator, value
    
    const stringMatch = condition.match(stringPattern)
    const numericMatch = condition.match(numericPattern)
    
    if (stringMatch) {
      [, variable, operator, value] = stringMatch
    } else if (numericMatch) {
      [, variable, operator, value] = numericMatch
    } else {
      return // Can't parse
    }
    
    // Set variable (will trigger handleVariableChange via event)
    if (this.hasVariableSelectTarget && variable) {
      // Need to load variables first if not already loaded
      if (this.variableSelectTarget.options.length <= 1) {
        this.loadVariablesFromForm()
      }
      this.variableSelectTarget.value = variable
      this.handleVariableChange()
    }
    
    // Set operator
    if (this.hasOperatorSelectTarget && operator) {
      this.operatorSelectTarget.value = operator
    }
    
    // Set value (after handleVariableChange creates the appropriate input)
    setTimeout(() => {
      const valueSelect = this.element.querySelector('[data-visual-condition-target="valueSelect"]')
      const valueInput = this.element.querySelector('[data-visual-condition-target="valueInput"]')
      
      if (valueSelect) {
        valueSelect.value = value
      } else if (valueInput) {
        valueInput.value = value
      }
      
      this.updatePreview()
    }, 50)
  }

  /**
   * Setup listener for form changes (new question steps added)
   */
  setupFormChangeListener() {
    const form = this.element.closest("form")
    if (!form) return
    
    this.formChangeHandler = (event) => {
      // Only refresh if a variable name changed
      if (event.target.matches && event.target.matches("input[name*='[variable_name]']")) {
        setTimeout(() => this.loadVariablesFromForm(), 100)
      }
    }
    
    form.addEventListener("input", this.formChangeHandler)
  }

  removeFormChangeListener() {
    const form = this.element.closest("form")
    if (form && this.formChangeHandler) {
      form.removeEventListener("input", this.formChangeHandler)
    }
  }

  /**
   * Escape HTML to prevent XSS
   */
  escapeHtml(text) {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }
}

