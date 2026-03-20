import { Controller } from "@hotwired/stimulus"

/**
 * Condition Preset Controller
 *
 * Provides smart preset dropdowns for transition conditions based on the
 * source step's type and configuration. Makes branching intuitive for
 * non-technical CSRs while preserving full customization capabilities.
 *
 * Targets:
 *   - presetDropdown: The main dropdown for selecting presets
 *   - customInput: Text input for custom conditions
 *   - customContainer: Container that shows/hides for custom input
 *   - labelInput: The label input field (to auto-fill)
 *   - numericValueInput: Input for numeric comparison values
 *   - numericContainer: Container for numeric input
 *   - conditionHidden: Hidden input holding the actual condition value
 *
 * Values:
 *   - condition: The current condition string
 *   - label: The current label string
 */
export default class extends Controller {
  static targets = [
    "presetDropdown",
    "customInput",
    "customContainer",
    "labelInput",
    "numericValueInput",
    "numericContainer",
    "conditionHidden"
  ]

  static values = {
    condition: String,
    label: String
  }

  connect() {
    // Allow DOM to settle before detecting step info
    setTimeout(() => {
      this.stepInfo = this.detectStepInfo()
      this.presets = this.buildPresets()
      this.labelManuallyEdited = false
      this.populateDropdown()
      this.restoreExistingCondition()
    }, 0)
  }

  /**
   * Detect the source step's type, answer_type, variable_name, and options
   * by reading from the DOM
   */
  detectStepInfo() {
    const stepItem = this.element.closest('.step-item')
    if (!stepItem) {
      return { stepType: null, answerType: null, variableName: null, options: [] }
    }

    // Get step type from hidden input (support both old and new markup)
    const typeInput = stepItem.querySelector('input[data-step-field="type"]') || stepItem.querySelector('input[name*="[type]"]')
    const stepType = typeInput?.value || null

    // Get answer type (for question steps) — check new data-step-field, form fields, and old markup
    const answerTypeDataField = stepItem.querySelector('input[data-step-field="answer_type"]')
    const answerTypeInput = stepItem.querySelector('input[name*="[answer_type]"]:checked')
    const hiddenAnswerType = stepItem.querySelector('input[name*="[answer_type]"][type="hidden"]')
    const answerType = answerTypeDataField?.value || answerTypeInput?.value || hiddenAnswerType?.value || null

    // Get variable name
    const variableNameDataField = stepItem.querySelector('input[data-step-field="variable_name"]')
    const variableNameInput = stepItem.querySelector('input[name*="[variable_name]"]')
    const variableName = variableNameDataField?.value || variableNameInput?.value || null

    // Get step title (fallback for variable name)
    const titleInput = stepItem.querySelector('input[data-step-field="title"]') || stepItem.querySelector('input[name*="[title]"]')
    const stepTitle = titleInput?.value || null

    // Get options (for multiple_choice and dropdown)
    const options = this.extractOptions(stepItem)

    return {
      stepType,
      answerType,
      variableName: variableName || this.sanitizeVariableName(stepTitle),
      stepTitle,
      options
    }
  }

  /**
   * Extract options from multiple choice / dropdown option inputs
   */
  extractOptions(stepItem) {
    const options = []
    const optionInputs = stepItem.querySelectorAll('input[name*="[options]"][name*="[label]"]')

    optionInputs.forEach((input, index) => {
      const label = input.value
      // Try to find corresponding value input
      const valueInput = stepItem.querySelectorAll('input[name*="[options]"][name*="[value]"]')[index]
      const value = valueInput?.value || label

      if (label) {
        options.push({ label, value })
      }
    })

    return options
  }

  /**
   * Sanitize a step title into a valid variable name
   */
  sanitizeVariableName(title) {
    if (!title) return 'answer'
    return title
      .toLowerCase()
      .replace(/[^a-z0-9_\s]/g, '')
      .replace(/\s+/g, '_')
      .substring(0, 30) || 'answer'
  }

  /**
   * Build the list of presets based on step info
   */
  buildPresets() {
    const presets = []
    const { stepType, answerType, variableName, options } = this.stepInfo
    const varName = variableName || 'answer'

    // Always add Default (no condition) first
    presets.push({
      id: '__default__',
      label: 'Default (no condition)',
      condition: '',
      displayLabel: 'Default'
    })

    // Question-specific presets based on answer_type
    if (stepType === 'question') {
      switch (answerType) {
        case 'yes_no':
          presets.push({
            id: 'yes',
            label: 'Yes',
            condition: `${varName} == 'Yes'`,
            displayLabel: 'Yes'
          })
          presets.push({
            id: 'no',
            label: 'No',
            condition: `${varName} == 'No'`,
            displayLabel: 'No'
          })
          break

        case 'multiple_choice':
        case 'dropdown':
          if (options && options.length > 0) {
            options.forEach((opt, idx) => {
              presets.push({
                id: `option_${idx}`,
                label: opt.label,
                condition: `${varName} == '${this.escapeQuotes(opt.value)}'`,
                displayLabel: opt.label
              })
            })
          }
          break

        case 'number':
          presets.push({
            id: 'num_gt',
            label: 'Greater than (>)',
            condition: null, // Will be filled with numeric value
            displayLabel: '> ',
            needsValue: true,
            operator: '>',
            valueType: 'number'
          })
          presets.push({
            id: 'num_gte',
            label: 'Greater than or equal (>=)',
            condition: null,
            displayLabel: '>= ',
            needsValue: true,
            operator: '>=',
            valueType: 'number'
          })
          presets.push({
            id: 'num_lt',
            label: 'Less than (<)',
            condition: null,
            displayLabel: '< ',
            needsValue: true,
            operator: '<',
            valueType: 'number'
          })
          presets.push({
            id: 'num_lte',
            label: 'Less than or equal (<=)',
            condition: null,
            displayLabel: '<= ',
            needsValue: true,
            operator: '<=',
            valueType: 'number'
          })
          presets.push({
            id: 'num_eq',
            label: 'Equals (==)',
            condition: null,
            displayLabel: '== ',
            needsValue: true,
            operator: '==',
            valueType: 'number'
          })
          presets.push({
            id: 'num_neq',
            label: 'Not equals (!=)',
            condition: null,
            displayLabel: '!= ',
            needsValue: true,
            operator: '!=',
            valueType: 'number'
          })
          break

        case 'text':
          presets.push({
            id: 'text_has_value',
            label: 'Has value',
            condition: `${varName} != ''`,
            displayLabel: 'Has value'
          })
          presets.push({
            id: 'text_empty',
            label: 'Is empty',
            condition: `${varName} == ''`,
            displayLabel: 'Empty'
          })
          break

        case 'file':
          presets.push({
            id: 'file_has',
            label: 'Has file',
            condition: `${varName} != ''`,
            displayLabel: 'Has file'
          })
          presets.push({
            id: 'file_no',
            label: 'No file',
            condition: `${varName} == ''`,
            displayLabel: 'No file'
          })
          break

        case 'date':
          // Date comparisons would need special handling
          // For now, just offer basic presets
          presets.push({
            id: 'date_has_value',
            label: 'Has date',
            condition: `${varName} != ''`,
            displayLabel: 'Has date'
          })
          presets.push({
            id: 'date_empty',
            label: 'No date',
            condition: `${varName} == ''`,
            displayLabel: 'No date'
          })
          break

        default:
          // No answer type set - just offer default presets
          break
      }
    }

    // Always add Custom option last
    presets.push({
      id: '__custom__',
      label: 'Custom...',
      condition: null,
      displayLabel: ''
    })

    return presets
  }

  /**
   * Escape single quotes in a string for use in conditions
   */
  escapeQuotes(str) {
    if (!str) return ''
    return str.replace(/'/g, "\\'")
  }

  /**
   * Populate the dropdown with presets
   */
  populateDropdown() {
    if (!this.hasPresetDropdownTarget) return

    const optionsHtml = this.presets.map(preset => {
      return `<option value="${preset.id}">${this.escapeHtml(preset.label)}</option>`
    }).join('')

    this.presetDropdownTarget.innerHTML = optionsHtml
  }

  /**
   * Restore existing condition by matching it to a preset or showing custom
   */
  restoreExistingCondition() {
    const condition = this.conditionValue || ''

    if (!condition || condition.trim() === '') {
      // No condition - select Default
      this.selectPreset('__default__')
      this.hideCustomInput()
      this.hideNumericInput()
      return
    }

    // Try to match against presets
    const matchedPreset = this.presets.find(p =>
      p.condition && p.condition === condition
    )

    if (matchedPreset) {
      this.selectPreset(matchedPreset.id)
      this.hideCustomInput()
      this.hideNumericInput()
      return
    }

    // Check if it matches a numeric preset pattern
    const numericMatch = this.matchNumericCondition(condition)
    if (numericMatch) {
      this.selectPreset(numericMatch.presetId)
      this.showNumericInput()
      this.setNumericValue(numericMatch.value)
      this.currentOperator = numericMatch.operator
      return
    }

    // No match - show custom input
    this.selectPreset('__custom__')
    this.showCustomInput()
    if (this.hasCustomInputTarget) {
      this.customInputTarget.value = condition
    }
  }

  /**
   * Try to match a condition against numeric preset patterns
   * Returns { presetId, operator, value } or null
   */
  matchNumericCondition(condition) {
    const varName = this.stepInfo?.variableName || 'answer'
    const operators = ['>=', '<=', '!=', '==', '>', '<']

    for (const op of operators) {
      const pattern = new RegExp(`^${this.escapeRegex(varName)}\\s*${this.escapeRegex(op)}\\s*(\\d+)$`)
      const match = condition.match(pattern)

      if (match) {
        const presetIdMap = {
          '>': 'num_gt',
          '>=': 'num_gte',
          '<': 'num_lt',
          '<=': 'num_lte',
          '==': 'num_eq',
          '!=': 'num_neq'
        }
        return {
          presetId: presetIdMap[op],
          operator: op,
          value: match[1]
        }
      }
    }

    return null
  }

  /**
   * Escape special regex characters
   */
  escapeRegex(str) {
    return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  }

  /**
   * Handle preset dropdown change
   */
  handlePresetChange(event) {
    const value = event.target.value
    const preset = this.presets.find(p => p.id === value)

    if (!preset) return

    if (value === '__custom__') {
      this.showCustomInput()
      this.hideNumericInput()
      // Clear condition and let user type
      this.updateCondition('')
      if (this.hasCustomInputTarget) {
        this.customInputTarget.focus()
      }
      return
    }

    if (value === '__default__') {
      this.hideCustomInput()
      this.hideNumericInput()
      this.updateCondition('')
      if (!this.labelManuallyEdited) {
        this.updateLabel('Default')
      }
      return
    }

    if (preset.needsValue) {
      this.hideCustomInput()
      this.showNumericInput()
      this.currentOperator = preset.operator
      // Don't update condition yet - wait for numeric value
      if (this.hasNumericValueInputTarget) {
        this.numericValueInputTarget.value = ''
        this.numericValueInputTarget.focus()
      }
      // Still update the label partial
      if (!this.labelManuallyEdited) {
        this.updateLabel(preset.displayLabel)
      }
      return
    }

    // Standard preset - update condition and label
    this.hideCustomInput()
    this.hideNumericInput()
    this.updateCondition(preset.condition)

    if (!this.labelManuallyEdited) {
      this.updateLabel(preset.displayLabel)
    }
  }

  /**
   * Handle custom input changes
   */
  handleCustomInput(event) {
    const condition = event.target.value
    this.updateCondition(condition)
  }

  /**
   * Handle numeric value input changes
   */
  handleNumericChange(event) {
    const numericValue = event.target.value
    if (!this.currentOperator || !numericValue) {
      this.updateCondition('')
      return
    }

    const varName = this.stepInfo?.variableName || 'answer'
    const condition = `${varName} ${this.currentOperator} ${numericValue}`
    this.updateCondition(condition)

    // Update label with the full expression
    if (!this.labelManuallyEdited) {
      this.updateLabel(`${this.currentOperator} ${numericValue}`)
    }
  }

  /**
   * Handle label input to detect manual edits
   */
  handleLabelInput(event) {
    // Mark as manually edited so we don't auto-fill anymore
    this.labelManuallyEdited = true
  }

  /**
   * Update the condition value and notify parent controller
   */
  updateCondition(condition) {
    // Update our value
    this.conditionValue = condition

    // Update hidden input if present
    if (this.hasConditionHiddenTarget) {
      this.conditionHiddenTarget.value = condition
    }

    // Find and update the main hidden condition field
    const transitionEl = this.element.closest('[data-transition-index]')
    if (transitionEl) {
      const hiddenField = transitionEl.querySelector('[data-transition-field="condition"]')
      if (hiddenField) {
        hiddenField.value = condition
      }
    }

    // Dispatch event for step-transitions controller to pick up
    this.element.dispatchEvent(new CustomEvent('condition-preset:change', {
      bubbles: true,
      detail: { condition }
    }))

    // Also trigger standard input event on hidden field for step-transitions sync
    if (this.hasConditionHiddenTarget) {
      this.conditionHiddenTarget.dispatchEvent(new Event('input', { bubbles: true }))
    }
  }

  /**
   * Update the label input
   */
  updateLabel(label) {
    if (!this.hasLabelInputTarget) return
    this.labelInputTarget.value = label

    // Trigger input event to notify step-transitions controller
    this.labelInputTarget.dispatchEvent(new Event('input', { bubbles: true }))
  }

  /**
   * Select a preset in the dropdown
   */
  selectPreset(presetId) {
    if (!this.hasPresetDropdownTarget) return
    this.presetDropdownTarget.value = presetId
  }

  /**
   * Show the custom input container
   */
  showCustomInput() {
    if (!this.hasCustomContainerTarget) return
    this.customContainerTarget.classList.remove('is-hidden')
  }

  /**
   * Hide the custom input container
   */
  hideCustomInput() {
    if (!this.hasCustomContainerTarget) return
    this.customContainerTarget.classList.add('is-hidden')
  }

  /**
   * Show the numeric input container
   */
  showNumericInput() {
    if (!this.hasNumericContainerTarget) return
    this.numericContainerTarget.classList.remove('is-hidden')
  }

  /**
   * Hide the numeric input container
   */
  hideNumericInput() {
    if (!this.hasNumericContainerTarget) return
    this.numericContainerTarget.classList.add('is-hidden')
  }

  /**
   * Set numeric value input
   */
  setNumericValue(value) {
    if (!this.hasNumericValueInputTarget) return
    this.numericValueInputTarget.value = value
  }

  /**
   * Escape HTML to prevent XSS
   */
  escapeHtml(text) {
    if (!text) return ''
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }
}
