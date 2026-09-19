import { Controller } from "@hotwired/stimulus"

/**
 * Condition Preset Controller
 *
 * Presets for this step's Yes/No and options; Custom is a sentence over
 * any question in the workflow (variable / operator / value) that writes
 * the ConditionEvaluator dialect. Unparseable strings stay Keep as written.
 */
export default class extends Controller {
  static targets = [
    "presetDropdown",
    "sentenceContainer",
    "sentenceVariable",
    "sentenceOperator",
    "sentenceValue",
    "keepAsWritten",
    "labelInput",
    "numericValueInput",
    "numericContainer",
    "conditionHidden"
  ]

  static values = {
    condition: String,
    label: String,
    variables: Array
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

    // Re-initialize presets when the source step's answer type changes
    this.boundRefreshPresets = this.refreshPresets.bind(this)
    const panelBody = this.element.closest('.builder__panel-body')
    if (panelBody) {
      panelBody.addEventListener('answer-type-changed', this.boundRefreshPresets)
    }
  }

  disconnect() {
    const panelBody = this.element.closest('.builder__panel-body')
    if (panelBody && this.boundRefreshPresets) {
      panelBody.removeEventListener('answer-type-changed', this.boundRefreshPresets)
    }
  }

  /**
   * Re-detect step info and rebuild presets (e.g. after answer_type change)
   */
  refreshPresets() {
    const currentCondition = this.conditionValue || ''
    this.stepInfo = this.detectStepInfo()
    this.presets = this.buildPresets()
    this.populateDropdown()
    // Try to restore the current condition against new presets
    this.conditionValue = currentCondition
    this.restoreExistingCondition()
  }

  /**
   * Detect the source step's type, answer_type, variable_name, and options
   * by reading from the DOM
   */
  detectStepInfo() {
    // Support both legacy step cards (.step-item) and builder panel forms
    const stepItem = this.element.closest('.step-item') || this.element.closest('.builder__panel-body')
    if (!stepItem) {
      return { stepType: null, answerType: null, variableName: null, options: [] }
    }

    // Get step type: panel body data attribute > hidden input > selected row fallback
    const panelBody = this.element.closest('.builder__panel-body')
    let stepType = panelBody?.dataset?.stepType || null
    if (!stepType) {
      const typeInput = stepItem.querySelector('input[data-step-field="type"]') || stepItem.querySelector('input[name*="[type]"]')
      stepType = typeInput?.value || null
    }
    if (!stepType) {
      const selectedRow = document.querySelector('.builder__step--selected')
      stepType = selectedRow?.dataset?.stepType || null
    }

    // Get answer type (for question steps) — check data-step-field, form fields, and radio buttons
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
          // Lowercase: the runner stores "yes"/"no", and imports write the
          // same. Capital Yes still restores via conditionsMatch.
          presets.push({
            id: 'yes',
            label: 'Yes',
            condition: `${varName} == 'yes'`,
            displayLabel: 'Yes'
          })
          presets.push({
            id: 'no',
            label: 'No',
            condition: `${varName} == 'no'`,
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
   * Escape a string for use as a single-quoted condition value: a backslash
   * first (or escaping the apostrophe would double-escape a backslash this
   * value already has), then the apostrophe - the same order
   * Step::Doors#condition_for escapes in, and what ConditionEvaluator's
   * tokenizer expects unescaping in reverse.
   */
  escapeQuotes(str) {
    if (!str) return ''
    return str.replace(/\\/g, "\\\\").replace(/'/g, "\\'")
  }

  /**
   * Populate the dropdown with presets
   * Trust boundary: preset.id is an internal constant; preset.label is escaped via escapeHtml.
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
      this.selectPreset('__default__')
      this.hideSentence()
      this.hideNumericInput()
      return
    }

    const matchedPreset = this.presets.find(p =>
      p.condition && this.conditionsMatch(p.condition, condition)
    )

    if (matchedPreset) {
      this.selectPreset(matchedPreset.id)
      this.hideSentence()
      this.hideNumericInput()
      return
    }

    const numericMatch = this.matchNumericCondition(condition)
    if (numericMatch) {
      this.selectPreset(numericMatch.presetId)
      this.hideSentence()
      this.showNumericInput()
      this.setNumericValue(numericMatch.value)
      this.currentOperator = numericMatch.operator
      return
    }

    this.selectPreset('__custom__')
    this.hideNumericInput()
    this.showSentence()

    const parsed = this.parseCondition(condition)
    if (parsed && this.fillSentence(parsed)) {
      this.hideKeepAsWritten()
      return
    }

    this.showKeepAsWritten(condition)
  }

  /**
   * Imports, this dropdown, and typed custom conditions disagree about
   * quotes and Yes vs yes. Compare the meaning.
   *
   * Preferred: parse both sides and compare variable/operator/value, taking
   * either of the stored side's two readings - the same "either reading"
   * rule ConditionEvaluator#value_matches? applies at runtime. This is what
   * lets an OLD-style stored condition for a backslash value
   * (`path == 'C:\temp'`, one backslash) still restore to a preset written
   * the new way (`path == 'C:\\temp'`, escaped) instead of dropping to
   * Custom: they parse to the same variable and operator, and the stored
   * side's literal reading (backslash kept) equals the preset's value.
   * Falls back to the plain-text normalisation below when either side does
   * not parse as one whole string or numeric comparison (a bare word like
   * "Yes", mismatched delimiters, trailing text) - `#parseCondition` cannot
   * help there and never could.
   */
  conditionsMatch(presetCondition, stored) {
    const preset = this.parseCondition(presetCondition)
    const storedParsed = this.parseCondition(stored)
    if (preset && storedParsed && preset.variable.toLowerCase() === storedParsed.variable.toLowerCase() &&
        preset.operator === storedParsed.operator) {
      const target = String(preset.value).toLowerCase()
      return String(storedParsed.value).toLowerCase() === target || String(storedParsed.rawValue).toLowerCase() === target
    }
    return this.normalizeCondition(presetCondition) === this.normalizeCondition(stored)
  }

  normalizeCondition(condition) {
    return condition
      .trim()
      .replace(/"/g, "'")
      .replace(/\s+/g, " ")
      .replace(/\s*([!=<>]+)\s*/g, " $1 ")
      .toLowerCase()
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
      this.hideNumericInput()
      this.showSentence()
      this.hideKeepAsWritten()
      this.prepareSentenceDefaults()
      return
    }

    if (value === '__default__') {
      this.hideSentence()
      this.hideNumericInput()
      this.updateCondition('')
      if (!this.labelManuallyEdited) {
        this.updateLabel('Default')
      }
      return
    }

    if (preset.needsValue) {
      this.hideSentence()
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

    this.hideSentence()
    this.hideNumericInput()
    this.updateCondition(preset.condition)

    if (!this.labelManuallyEdited) {
      this.updateLabel(preset.displayLabel)
    }
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

  showSentence() {
    if (!this.hasSentenceContainerTarget) return
    this.sentenceContainerTarget.classList.remove('is-hidden')
    this.populateVariableSelect(this.sentenceVariableTarget.value || this.defaultVariableName())
    this.applyControlsForCurrentVariable()
  }

  hideSentence() {
    if (!this.hasSentenceContainerTarget) return
    this.sentenceContainerTarget.classList.add('is-hidden')
    this.hideKeepAsWritten()
  }

  prepareSentenceDefaults() {
    this.populateVariableSelect(this.defaultVariableName())
    this.applyControlsForCurrentVariable()
  }

  defaultVariableName() {
    const names = (this.variablesValue || []).map(v => v.name)
    const mine = this.stepInfo?.variableName
    if (mine && names.includes(mine)) return mine
    return names[0] || ''
  }

  populateVariableSelect(selectedName) {
    if (!this.hasSentenceVariableTarget) return
    const vars = this.variablesValue || []
    this.sentenceVariableTarget.innerHTML = vars.map(variable => {
      const selected = variable.name === selectedName ? 'selected' : ''
      return `<option value="${this.escapeHtml(variable.name)}" ${selected}>${this.escapeHtml(variable.title || variable.name)}</option>`
    }).join('')
  }

  currentVariableMeta() {
    const name = this.hasSentenceVariableTarget ? this.sentenceVariableTarget.value : ''
    return (this.variablesValue || []).find(v => v.name === name) || null
  }

  applyControlsForCurrentVariable(preferredOperator = null, preferredValue = null) {
    const meta = this.currentVariableMeta()
    const numeric = meta?.answer_type === 'number'
    this.populateOperators(numeric, preferredOperator)
    return this.populateValueControl(meta, preferredValue)
  }

  populateOperators(numeric, preferredOperator) {
    if (!this.hasSentenceOperatorTarget) return
    const operators = numeric
      ? [
          { value: '==', label: 'equals' },
          { value: '!=', label: 'does not equal' },
          { value: '>', label: 'greater than' },
          { value: '>=', label: 'at least' },
          { value: '<', label: 'less than' },
          { value: '<=', label: 'at most' }
        ]
      : [
          { value: '==', label: 'is' },
          { value: '!=', label: 'is not' }
        ]
    const selected = preferredOperator || operators[0].value
    this.sentenceOperatorTarget.innerHTML = operators.map(op => {
      const isSelected = op.value === selected ? 'selected' : ''
      return `<option value="${op.value}" ${isSelected}>${op.label}</option>`
    }).join('')
  }

  populateValueControl(meta, preferredValue) {
    if (!this.hasSentenceValueTarget) return true
    const answerType = meta?.answer_type
    const options = this.valueOptionsFor(meta)

    if (answerType === 'number') {
      const value = preferredValue ?? ''
      this.sentenceValueTarget.innerHTML =
        `<input type="number" class="form-input" value="${this.escapeHtml(String(value))}"
                data-action="input->condition-preset#handleSentenceChange"
                aria-label="Condition value">`
      return true
    }

    if (options.length > 0) {
      if (preferredValue != null && preferredValue !== '' &&
          !options.some(opt => String(opt.value) === String(preferredValue))) {
        return false
      }
      const selected = preferredValue ?? ''
      const opts = options.map(opt => {
        const isSelected = String(opt.value) === String(selected) ? 'selected' : ''
        return `<option value="${this.escapeHtml(String(opt.value))}" ${isSelected}>${this.escapeHtml(opt.label)}</option>`
      }).join('')
      this.sentenceValueTarget.innerHTML =
        `<select class="form-select" data-action="change->condition-preset#handleSentenceChange"
                 aria-label="Condition value">${opts}</select>`
      return true
    }

    const value = preferredValue ?? ''
    this.sentenceValueTarget.innerHTML =
      `<input type="text" class="form-input" value="${this.escapeHtml(String(value))}"
              data-action="input->condition-preset#handleSentenceChange"
              aria-label="Condition value">`
    return true
  }

  valueOptionsFor(meta) {
    if (!meta) return []
    if (meta.answer_type === 'yes_no') {
      return [{ label: 'Yes', value: 'yes' }, { label: 'No', value: 'no' }]
    }
    if (meta.answer_type === 'multiple_choice' || meta.answer_type === 'dropdown') {
      return (meta.options || []).map(opt => ({
        label: opt.label || opt.value,
        value: opt.value || opt.label
      })).filter(opt => opt.value)
    }
    return []
  }

  sentenceValueNow() {
    if (!this.hasSentenceValueTarget) return ''
    const select = this.sentenceValueTarget.querySelector('select')
    if (select) return select.value
    const input = this.sentenceValueTarget.querySelector('input')
    return input ? input.value : ''
  }

  handleSentenceChange(event) {
    if (event?.target === this.sentenceVariableTarget) {
      this.applyControlsForCurrentVariable()
    }
    this.writeSentenceCondition()
  }

  writeSentenceCondition() {
    const variable = this.hasSentenceVariableTarget ? this.sentenceVariableTarget.value : ''
    const operator = this.hasSentenceOperatorTarget ? this.sentenceOperatorTarget.value : '=='
    const value = this.sentenceValueNow()
    if (!variable || value === '') return

    this.hideKeepAsWritten()
    const meta = this.currentVariableMeta()
    const numericOps = ['>', '>=', '<', '<=']
    const numericEquals = meta?.answer_type === 'number' && (operator === '==' || operator === '!=')
    const condition = (numericOps.includes(operator) || numericEquals)
      ? `${variable} ${operator} ${value}`
      : `${variable} ${operator} '${this.escapeQuotes(value)}'`
    this.updateCondition(condition)
  }

  /**
   * A string comparison's value has two readings, same as
   * ConditionEvaluator#parse on the Ruby side: `value` is unescaped (`\'`
   * becomes `'`, `\\` becomes `\`), `rawValue` is the literal text between
   * the delimiters, backslashes kept. Both are returned so #conditionsMatch
   * can accept either, the way the runner does.
   */
  parseCondition(condition) {
    const trimmed = condition.trim()
    const stringMatch = trimmed.match(/^(\w+)\s*(==|!=)\s*(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")\s*$/)
    if (stringMatch) {
      const raw = stringMatch[3] ?? stringMatch[4]
      return { variable: stringMatch[1], operator: stringMatch[2], value: raw.replace(/\\(.)/g, "$1"), rawValue: raw }
    }
    // A value ending in a bare, un-escaped backslash ('C:\') has no valid
    // close under the escape-aware pattern above - the trailing backslash
    // consumes the closing quote as an "escaped" character. Matched-delimiter
    // subset of ConditionEvaluator::PRE_TASK_STRING_VALUE (which also accepts
    // mismatched delimiters, so complete?/valid? stay a superset of what they
    // always accepted; a mismatched-delimiter condition can safely fall to
    // Custom here instead), with no escape understanding at all, so a
    // condition written before backslashes were escaped still restores to
    // its preset instead of falling to Custom.
    const legacyMatch = trimmed.match(/^(\w+)\s*(==|!=)\s*(?:'([^'"]*)'|"([^'"]*)")\s*$/)
    if (legacyMatch) {
      const raw = legacyMatch[3] ?? legacyMatch[4]
      return { variable: legacyMatch[1], operator: legacyMatch[2], value: raw, rawValue: raw }
    }
    const numericMatch = trimmed.match(/^(\w+)\s*(==|!=|>|>=|<|<=)\s*(\d+)\s*$/)
    if (numericMatch) {
      return { variable: numericMatch[1], operator: numericMatch[2], value: numericMatch[3], rawValue: numericMatch[3] }
    }
    return null
  }

  fillSentence(parsed) {
    const names = (this.variablesValue || []).map(v => v.name)
    if (!names.includes(parsed.variable)) return false

    this.populateVariableSelect(parsed.variable)
    return this.applyControlsForCurrentVariable(parsed.operator, parsed.value)
  }

  showKeepAsWritten(text) {
    if (!this.hasKeepAsWrittenTarget) return
    this.keepAsWrittenTarget.textContent = `Keep as written: ${text}`
    this.keepAsWrittenTarget.hidden = false
    this.keepAsWrittenTarget.classList.remove('is-hidden')
  }

  hideKeepAsWritten() {
    if (!this.hasKeepAsWrittenTarget) return
    this.keepAsWrittenTarget.textContent = ''
    this.keepAsWrittenTarget.hidden = true
    this.keepAsWrittenTarget.classList.add('is-hidden')
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
