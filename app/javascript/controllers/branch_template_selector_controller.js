import { Controller } from "@hotwired/stimulus"
import { BranchTemplateService } from "services/branch_template_service"
import { renderIcon, UI_ICON_PATHS, ANSWER_ICON_PATHS } from "services/icon_service"

export default class extends Controller {
  static targets = ["panel", "templatesContainer", "customizationPanel", "customizationContent", "backdrop"]
  static values = {
    variable: String,
    answerType: String
  }

  connect() {
    console.log('[Branch Template Selector] Controller connected')
    this.selectedTemplate = null
    this.customizations = {}
    
    // Listen for variable changes from rule builder
    this.setupVariableListener()
    
    // Load templates initially
    this.loadTemplates()
    
    // Test if templates container exists
    if (this.hasTemplatesContainerTarget) {
      console.log('[Branch Template Selector] Templates container found')
    } else {
      console.warn('[Branch Template Selector] Templates container NOT found')
    }
  }
  
  setupVariableListener() {
    // Find all rule builders in the form and listen for variable changes
    this.form = this.element.closest("form")
    if (!this.form) return

    // Debounce to prevent multiple rapid calls
    this.loadTimeout = null

    // Store bound handler for cleanup
    this.boundFormChangeHandler = (event) => {
      if (event.target.matches('[data-rule-builder-target="variableSelect"]')) {
        this.variableValue = event.target.value
        // Only reload if panel is visible
        if (this.hasPanelTarget && !this.panelTarget.classList.contains('is-hidden')) {
          if (this.loadTimeout) clearTimeout(this.loadTimeout)
          this.loadTimeout = setTimeout(() => {
            this.loadTemplates()
          }, 300)
        }
      }
    }

    this.form.addEventListener('change', this.boundFormChangeHandler)
  }

  loadTemplates() {
    if (!this.hasTemplatesContainerTarget) {
      console.warn('[Branch Template Selector] Templates container target not found')
      return
    }
    
    console.log('[Branch Template Selector] Loading templates...')
    
    // Get suitable templates based on variable and answer type
    const templates = BranchTemplateService.getSuitableTemplates(
      this.variableValue || '',
      this.answerTypeValue || '',
      []
    )
    
    // If no variable selected, show all templates
    const allTemplates = this.variableValue 
      ? templates 
      : BranchTemplateService.getTemplates()
    
    console.log('[Branch Template Selector] Found', allTemplates.length, 'templates')
    
    // Render templates
    // Trust boundary: renderTemplateCard escapes all user-supplied values via escapeHtml.
    const templatesHtml = allTemplates.map(template => {
      return this.renderTemplateCard(template)
    }).join('')

    this.templatesContainerTarget.innerHTML = templatesHtml
    
    // Immediately attach event listeners (don't use setTimeout)
    this.attachTemplateButtonListeners()
  }
  
  attachTemplateButtonListeners() {
    const buttons = this.templatesContainerTarget.querySelectorAll('[data-template-id]')
    console.log('[Branch Template Selector] Attaching listeners to', buttons.length, 'buttons')
    
    buttons.forEach((button, index) => {
      const templateId = button.dataset.templateId || button.getAttribute('data-template-id')
      
      if (!templateId) {
        console.warn(`[Branch Template Selector] Button ${index} has no template ID`)
        return
      }
      
      // Remove disabled attribute
      button.removeAttribute('disabled')
      button.disabled = false
      
      // Remove all existing listeners by cloning
      const newButton = button.cloneNode(true)
      newButton.dataset.templateId = templateId
      button.parentNode.replaceChild(newButton, button)
      
      // Create handler that uses newButton and binds to controller
      const controller = this
      const handler = function(e) {
        if (e) {
          e.preventDefault()
          e.stopPropagation()
        }
        console.log('[Branch Template Selector] Button clicked handler fired:', templateId, 'Event:', e)
        controller.selectTemplate({ 
          currentTarget: this, 
          target: this,
          preventDefault: () => {},
          stopPropagation: () => {}
        })
      }
      
      // Attach listeners to new button - use capture phase first to catch early
      newButton.addEventListener('click', handler.bind(newButton), true) // Capture phase
      newButton.addEventListener('click', handler.bind(newButton), false) // Bubble phase
      newButton.addEventListener('mousedown', function(e) {
        e.stopPropagation()
        console.log('[Branch Template Selector] Mousedown on button:', templateId)
      }, true)
      
      // Store controller reference on button for onclick access
      newButton._templateController = controller
      newButton._templateId = templateId
      
      // Set onclick directly - this should work even if addEventListener doesn't
      newButton.onclick = function(e) {
        e.preventDefault()
        e.stopPropagation()
        console.log('[Branch Template Selector] Direct onclick fired:', this._templateId)
        if (this._templateController) {
          this._templateController.selectTemplate({ 
            currentTarget: this, 
            target: this,
            preventDefault: () => {},
            stopPropagation: () => {}
          })
        }
        return false
      }
      
      console.log(`[Branch Template Selector] Listeners attached to button ${index} (${templateId})`)
    })
  }

  resolveTemplateIcon(iconKey) {
    const allPaths = { ...UI_ICON_PATHS, ...ANSWER_ICON_PATHS }
    const pathData = allPaths[iconKey]
    if (pathData) return renderIcon(pathData, "icon")
    return renderIcon(UI_ICON_PATHS.lightbulb, "icon")
  }

  renderTemplateCard(template) {
    const branchesCount = template.branches ? template.branches.length : 'N'
    // Don't disable buttons - let the handler check and show alert if needed
    const requiresVariable = template.requiresVariable && !this.variableValue

    return `
      <div class="template-card ${requiresVariable ? 'is-disabled' : ''}">
        <div class="template-card__header">
          <span class="template-card__icon">${this.resolveTemplateIcon(template.icon)}</span>
          <div class="template-card__body">
            <h5 class="template-card__name">${this.escapeHtml(template.name)}</h5>
            <p class="template-card__description">${this.escapeHtml(template.description)}</p>
          </div>
        </div>

        <div class="template-card__footer">
          <span class="template-card__branches">${branchesCount} branch${branchesCount !== 'N' && branchesCount !== 1 ? 'es' : ''}</span>
          <button type="button"
                  class="btn btn--primary btn--sm ${requiresVariable ? 'is-disabled' : ''}"
                  data-template-id="${template.id}"
                  data-action="click->branch-template-selector#selectTemplate"
                  onclick="console.log('Button clicked via onclick:', '${template.id}'); return false;">
            Use Template
          </button>
        </div>
      </div>
    `
  }

  selectTemplate(event) {
    console.log('[Branch Template Selector] selectTemplate called', event)
    
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    
    const button = event ? event.currentTarget : event.target
    const templateId = button ? (button.dataset.templateId || button.getAttribute('data-template-id')) : null
    
    if (!templateId) {
      console.error('[Branch Template] No template ID found')
      return
    }
    
    console.log('[Branch Template] Template selected:', templateId)
    
    const template = BranchTemplateService.getTemplate(templateId)
    
    if (!template) {
      console.warn('[Branch Template] Template not found:', templateId)
      return
    }
    
    // Check if variable is required
    if (template.requiresVariable && !this.variableValue) {
      // Try to detect variable from form
      this.detectVariableFromForm()
      
      if (!this.variableValue) {
        alert('Please select a variable in one of the branches first, or create a question step with a variable name.')
        return
      }
    }
    
    this.selectedTemplate = template
    console.log('[Branch Template] Selected template:', template)
    
    // Check if template needs customization
    if (template.customizable) {
      this.showCustomizationPanel(template)
    } else {
      // Apply template directly
      this.applyTemplate()
    }
  }

  showCustomizationPanel(template) {
    if (!this.hasCustomizationPanelTarget || !this.hasCustomizationContentTarget) return
    
    let customizationHtml = ''

    if (template.id === 'numeric_range') {
      // Trust boundary: renderNumericRangeCustomization escapes user values via escapeHtml.
      customizationHtml = this.renderNumericRangeCustomization(template)
    }

    this.customizationContentTarget.innerHTML = customizationHtml
    this.customizationPanelTarget.classList.remove('is-hidden')
    
    // Scroll to customization panel
    this.customizationPanelTarget.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
  }

  renderNumericRangeCustomization(template) {
    const ranges = template.customizable.ranges || []
    
    return `
      <div class="range-customization">
        ${ranges.map((range, index) => `
          <div class="range-customization__row">
            <label class="range-label">${this.escapeHtml(range.label)}:</label>
            ${range.operator2 ? `
              <input type="number"
                     class="range-customization__input"
                     value="${range.value}"
                     data-range-index="${index}"
                     data-range-field="value">
              <span class="range-separator">to</span>
              <input type="number"
                     class="range-customization__input"
                     value="${range.value2}"
                     data-range-index="${index}"
                     data-range-field="value2">
            ` : `
              <select class="range-customization__select"
                      data-range-index="${index}"
                      data-range-field="operator">
                <option value=">" ${range.operator === '>' ? 'selected' : ''}>></option>
                <option value=">=" ${range.operator === '>=' ? 'selected' : ''}>>=</option>
                <option value="<" ${range.operator === '<' ? 'selected' : ''}><</option>
                <option value="<=" ${range.operator === '<=' ? 'selected' : ''}><=</option>
              </select>
              <input type="number"
                     class="range-customization__input"
                     value="${range.value}"
                     data-range-index="${index}"
                     data-range-field="value">
            `}
          </div>
        `).join('')}
      </div>
    `
  }

  applyTemplate(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    
    if (!this.selectedTemplate) {
      console.warn('[Branch Template] No template selected')
      return
    }
    
    console.log('[Branch Template] Applying template:', this.selectedTemplate.id)
    
    // Get variable from form if not set
    if (!this.variableValue) {
      this.detectVariableFromForm()
    }
    
    console.log('[Branch Template] Variable:', this.variableValue)
    
    // For templates that require a variable, check if we have one
    if (this.selectedTemplate.requiresVariable && !this.variableValue) {
      alert('Please select a variable in one of the branches first, or create a question step with a variable name.')
      return
    }
    
    console.log('[Branch Template] Applying template:', this.selectedTemplate.id)
    console.log('[Branch Template] Variable:', this.variableValue)
    
    // Get customizations if any
    if (this.hasCustomizationContentTarget) {
      this.collectCustomizations()
    }
    
    // Generate branches
    let branches = []
    try {
      // Get options if needed (for multiple choice)
      const options = this.getOptionsForVariable()
      
      // Use a default variable if none is set (for templates that don't require it)
      const variable = this.variableValue || 'variable'
      
      console.log('[Branch Template] Generating branches with:', {
        templateId: this.selectedTemplate.id,
        variable,
        options,
        customizations: this.customizations
      })
      
      branches = BranchTemplateService.generateBranches(
        this.selectedTemplate.id,
        variable,
        options,
        this.customizations
      )
      
      console.log('[Branch Template] Generated branches:', branches)
    } catch (error) {
      alert(`Error: ${error.message}`)
      console.error('[Branch Template] Error generating branches:', error)
      return
    }
    
    if (!branches || branches.length === 0) {
      alert('No branches were generated. Please check your template selection.')
      return
    }
    
    // Find the multi-branch controller element (parent container)
    const multiBranchElement = this.element.closest('[data-controller*="multi-branch"]')
    if (!multiBranchElement) {
      console.error('[Branch Template] Multi-branch controller not found')
      alert('Could not find the branch container. Please refresh the page.')
      return
    }
    
    console.log('[Branch Template] Dispatching event to:', multiBranchElement)
    
    // Dispatch event to apply branches - dispatch on the multi-branch element
    const templateEvent = new CustomEvent('template-applied', {
      detail: { branches },
      bubbles: true,
      cancelable: true
    })
    
    multiBranchElement.dispatchEvent(templateEvent)
    
    console.log('[Branch Template] Event dispatched, defaultPrevented:', templateEvent.defaultPrevented)
    
    // Also try dispatching on the element itself as fallback
    if (!templateEvent.defaultPrevented) {
      this.element.dispatchEvent(new CustomEvent('template-applied', {
        detail: { branches },
        bubbles: true
      }))
    }
    
    // Hide panels
    this.hideCustomizationPanel()
    
    // Close panel after applying
    this.togglePanel()
  }
  
  detectVariableFromForm() {
    // Try to find a variable from existing branches or question steps
    const form = this.element.closest("form")
    if (!form) return
    
    // First, check if there are any branches with variables selected
    const variableSelects = form.querySelectorAll('[data-rule-builder-target="variableSelect"]')
    for (const select of variableSelects) {
      if (select.value && select.value.trim()) {
        this.variableValue = select.value.trim()
        return
      }
    }
    
    // If no branches have variables, check question steps
    const stepItems = form.querySelectorAll(".step-item")
    for (const stepItem of stepItems) {
      const typeInput = stepItem.querySelector("input[name*='[type]']")
      if (!typeInput || typeInput.value !== "question") continue
      
      const variableInput = stepItem.querySelector("input[name*='[variable_name]']")
      if (variableInput && variableInput.value.trim()) {
        this.variableValue = variableInput.value.trim()
        return
      }
    }
  }

  collectCustomizations() {
    if (!this.hasCustomizationContentTarget) return
    
    const inputs = this.customizationContentTarget.querySelectorAll('[data-range-index]')
    const ranges = []
    
    inputs.forEach(input => {
      const index = parseInt(input.dataset.rangeIndex)
      const field = input.dataset.rangeField
      
      if (!ranges[index]) {
        ranges[index] = {}
      }
      
      ranges[index][field] = input.value
    })
    
    this.customizations = { ranges }
  }

  getOptionsForVariable() {
    // Try to find options from the form
    const form = this.element.closest("form")
    if (!form) return []
    
    const stepItems = form.querySelectorAll(".step-item")
    for (const stepItem of stepItems) {
      const typeInput = stepItem.querySelector("input[name*='[type]']")
      if (!typeInput || typeInput.value !== "question") continue
      
      const variableInput = stepItem.querySelector("input[name*='[variable_name]']")
      const variableName = variableInput ? variableInput.value.trim() : ""
      
      if (variableName === this.variableValue) {
        // Get options
        const optionInputs = stepItem.querySelectorAll("input[name*='[options]'][name*='[label]']")
        return Array.from(optionInputs).map(input => {
          const valueInput = input.closest('.option-item')?.querySelector("input[name*='[value]']")
          return {
            label: input.value,
            value: valueInput ? valueInput.value : input.value
          }
        }).filter(opt => opt.label || opt.value)
      }
    }
    
    return []
  }

  cancelCustomization() {
    this.hideCustomizationPanel()
    this.selectedTemplate = null
    this.customizations = {}
  }

  hideCustomizationPanel() {
    if (this.hasCustomizationPanelTarget) {
      this.customizationPanelTarget.classList.add('is-hidden')
    }
  }

  togglePanel(event) {
    // Don't close if clicking inside the modal content
    if (event && event.target.closest('.pointer-events-auto')) {
      return
    }
    
    // Don't close if clicking the backdrop (only close on backdrop itself)
    if (event && event.target === this.backdropTarget) {
      // Continue to close
    } else if (event && event.target !== event.currentTarget && !event.target.closest('[data-branch-template-selector-target="panel"]')) {
      // Clicked outside, continue to close
    } else if (event && event.target.closest('[data-branch-template-selector-target="panel"]')) {
      // Clicked inside modal, don't close
      return
    }
    
    if (!this.hasPanelTarget) return
    
    const isHidden = this.panelTarget.classList.contains('is-hidden')
    
    if (isHidden) {
      // Show panel and backdrop
      this.panelTarget.classList.remove('is-hidden')
      if (this.hasBackdropTarget) {
        this.backdropTarget.classList.remove('is-hidden')
      }
      this.loadTemplates()
      
      // Prevent body scroll
      document.body.style.overflow = 'hidden'
      
      // Close on escape key
      this.escapeHandler = this.handleEscape.bind(this)
      document.addEventListener('keydown', this.escapeHandler)
    } else {
      // Hide panel and backdrop
      this.panelTarget.classList.add('is-hidden')
      if (this.hasBackdropTarget) {
        this.backdropTarget.classList.add('is-hidden')
      }
      
      // Restore body scroll
      document.body.style.overflow = ''
      
      // Remove escape handler
      if (this.escapeHandler) {
        document.removeEventListener('keydown', this.escapeHandler)
        this.escapeHandler = null
      }
      
      // Cancel any customization
      this.cancelCustomization()
    }
  }
  
  handleEscape(event) {
    if (event.key === 'Escape') {
      this.togglePanel()
    }
  }
  
  disconnect() {
    if (this.escapeHandler) {
      document.removeEventListener('keydown', this.escapeHandler)
    }
    // Clean up form change listener
    if (this.form && this.boundFormChangeHandler) {
      this.form.removeEventListener('change', this.boundFormChangeHandler)
    }
    // Clear debounce timer
    if (this.loadTimeout) {
      clearTimeout(this.loadTimeout)
    }
    // Restore body scroll if panel was open
    document.body.style.overflow = ''
  }

  stopPropagation(event) {
    event.stopPropagation()
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}

