import { Controller } from "@hotwired/stimulus"

// Provides variable autocomplete when typing {{ in text inputs/textareas
// Shows a dropdown with available variables from the workflow
export default class extends Controller {
  static targets = ["input"]
  static values = { 
    workflowId: Number,
    variablesUrl: String
  }

  connect() {
    this.variables = []
    this.dropdown = null
    this.dropdownContainer = null
    this.currentStartPos = -1
    this.currentEndPos = -1
    this.filteredVariables = []
    
    // Load variables if workflow ID is provided
    if (this.workflowIdValue) {
      this.loadVariables()
    }
    
    // Store bound references so removeEventListener works correctly
    this.boundHandleInput = this.handleInput.bind(this)
    this.boundHandleKeydown = this.handleKeydown.bind(this)
    this.boundHandleBlur = this.handleBlur.bind(this)
    this.boundHandleDocumentClick = this.handleDocumentClick.bind(this)

    // Set up input listeners
    this.inputTargets.forEach(input => {
      input.addEventListener("input", this.boundHandleInput)
      input.addEventListener("keydown", this.boundHandleKeydown)
      input.addEventListener("blur", this.boundHandleBlur, true) // Use capture phase
    })

    // Hide dropdown when clicking outside
    document.addEventListener("click", this.boundHandleDocumentClick)
    
    // Reload variables when steps are added/removed
    this.boundStepChangeHandler = () => {
      // Debounce variable reload
      if (this.reloadDebounceTimer) {
        clearTimeout(this.reloadDebounceTimer)
      }
      this.reloadDebounceTimer = setTimeout(() => {
        if (this.workflowIdValue) {
          this.loadVariables()
        }
      }, 500)
    }
    document.addEventListener("workflow-builder:step-added", this.boundStepChangeHandler)
    document.addEventListener("workflow-builder:step-removed", this.boundStepChangeHandler)
  }

  disconnect() {
    this.inputTargets.forEach(input => {
      input.removeEventListener("input", this.boundHandleInput)
      input.removeEventListener("keydown", this.boundHandleKeydown)
      input.removeEventListener("blur", this.boundHandleBlur, true)
    })
    document.removeEventListener("click", this.boundHandleDocumentClick)
    document.removeEventListener("workflow-builder:step-added", this.boundStepChangeHandler)
    document.removeEventListener("workflow-builder:step-removed", this.boundStepChangeHandler)
    if (this.reloadDebounceTimer) {
      clearTimeout(this.reloadDebounceTimer)
    }
    this.removeDropdown()
  }

  async loadVariables() {
    try {
      const url = this.variablesUrlValue || `/workflows/${this.workflowIdValue}/variables.json`
      const response = await fetch(url)
      const data = await response.json()
      
      if (data.variables && Array.isArray(data.variables)) {
        this.variables = data.variables
      }
    } catch (error) {
      console.error("Failed to load variables:", error)
      this.variables = []
    }
  }

  handleInput(event) {
    const input = event.target
    const value = input.value
    const cursorPos = input.selectionStart
    
    // Check if we're inside {{ ... }}
    const beforeCursor = value.substring(0, cursorPos)
    const lastOpenBrace = beforeCursor.lastIndexOf("{{")
    
    if (lastOpenBrace === -1) {
      this.hideDropdown()
      return
    }
    
    // Check if there's a closing }} after the opening {{
    const afterOpenBrace = value.substring(lastOpenBrace)
    const nextCloseBrace = afterOpenBrace.indexOf("}}")
    
    // Only show dropdown if we're between {{ and }} (or }} doesn't exist yet)
    if (nextCloseBrace === -1 || nextCloseBrace > (cursorPos - lastOpenBrace)) {
      // Extract the text between {{ and cursor
      const varText = beforeCursor.substring(lastOpenBrace + 2).trim()
      
      // Filter variables
      this.filteredVariables = this.variables.filter(v => 
        v.toLowerCase().includes(varText.toLowerCase())
      )
      
      if (this.filteredVariables.length > 0) {
        this.currentStartPos = lastOpenBrace + 2
        this.currentEndPos = cursorPos
        this.showDropdown(input, lastOpenBrace)
      } else {
        this.hideDropdown()
      }
    } else {
      this.hideDropdown()
    }
  }

  handleKeydown(event) {
    if (!this.dropdown || !this.dropdownContainer) return
    
    const selectedItem = this.dropdownContainer.querySelector(".variable-item.is-selected")
    
    switch (event.key) {
      case "ArrowDown":
        event.preventDefault()
        this.selectNext()
        break
      case "ArrowUp":
        event.preventDefault()
        this.selectPrevious()
        break
      case "Enter":
      case "Tab":
        if (selectedItem) {
          event.preventDefault()
          this.insertVariable(selectedItem.dataset.variable)
        }
        break
      case "Escape":
        this.hideDropdown()
        break
    }
  }

  handleBlur(event) {
    // Delay hiding to allow click events on dropdown items to fire first
    setTimeout(() => {
      if (!this.dropdown || !this.dropdown.contains(document.activeElement)) {
        this.hideDropdown()
      }
    }, 200)
  }

  handleDocumentClick(event) {
    if (this.dropdown && !this.dropdown.contains(event.target) && 
        !this.inputTargets.includes(event.target)) {
      this.hideDropdown()
    }
  }

  showDropdown(input, openBracePos) {
    if (!this.filteredVariables.length) return
    
    // Remove existing dropdown
    this.removeDropdown()
    
    // Create dropdown container
    this.dropdownContainer = document.createElement("div")
    this.dropdownContainer.className = "variable-autocomplete-dropdown"
    
    // Create variable list
    this.filteredVariables.forEach((variable, index) => {
      const item = document.createElement("div")
      item.className = `variable-item${index === 0 ? ' is-selected' : ''}`
      item.dataset.variable = variable
      item.textContent = variable
      item.addEventListener("click", () => {
        this.insertVariable(variable)
      })
      this.dropdownContainer.appendChild(item)
    })
    
    // Position dropdown near the cursor
    const inputRect = input.getBoundingClientRect()
    const scrollTop = window.pageYOffset || document.documentElement.scrollTop
    const scrollLeft = window.pageXOffset || document.documentElement.scrollLeft
    
    // Calculate position - try to align with the {{ location
    // For simplicity, position below the input
    this.dropdown = document.createElement("div")
    this.dropdown.style.position = "absolute"
    this.dropdown.style.top = `${inputRect.bottom + scrollTop + 4}px`
    this.dropdown.style.left = `${inputRect.left + scrollLeft}px`
    this.dropdown.style.minWidth = `${inputRect.width}px`
    this.dropdown.appendChild(this.dropdownContainer)
    
    document.body.appendChild(this.dropdown)
  }

  hideDropdown() {
    this.removeDropdown()
    this.currentStartPos = -1
    this.currentEndPos = -1
    this.filteredVariables = []
  }

  removeDropdown() {
    if (this.dropdown && this.dropdown.parentNode) {
      this.dropdown.parentNode.removeChild(this.dropdown)
    }
    this.dropdown = null
    this.dropdownContainer = null
  }

  selectNext() {
    if (!this.dropdownContainer) return
    
    const items = this.dropdownContainer.querySelectorAll(".variable-item")
    const selected = this.dropdownContainer.querySelector(".variable-item.is-selected")
    
    if (selected) {
      selected.classList.remove("is-selected")
      const next = selected.nextElementSibling
      if (next) {
        next.classList.add("is-selected")
        next.scrollIntoView({ block: "nearest" })
      }
    } else if (items.length > 0) {
      items[0].classList.add("is-selected")
    }
  }

  selectPrevious() {
    if (!this.dropdownContainer) return
    
    const items = this.dropdownContainer.querySelectorAll(".variable-item")
    const selected = this.dropdownContainer.querySelector(".variable-item.is-selected")
    
    if (selected) {
      selected.classList.remove("is-selected")
      const prev = selected.previousElementSibling
      if (prev) {
        prev.classList.add("is-selected")
        prev.scrollIntoView({ block: "nearest" })
      }
    } else if (items.length > 0) {
      items[items.length - 1].classList.add("is-selected")
    }
  }

  insertVariable(variable) {
    // Find the currently focused input
    let input = document.activeElement
    if (!input || (this.inputTargets.length > 0 && !this.inputTargets.includes(input))) {
      // Fallback to first input target if no focused element
      if (this.inputTargets.length === 0) return
      input = this.inputTargets[0]
    }
    
    if (!input) return
    
    const value = input.value
    const cursorPos = input.selectionStart || value.length
    
    // Find the {{ position
    const beforeCursor = value.substring(0, cursorPos)
    const lastOpenBrace = beforeCursor.lastIndexOf("{{")
    
    if (lastOpenBrace === -1) {
      // Just insert {{variable_name}}
      const newValue = value.substring(0, cursorPos) + `{{${variable}}}` + value.substring(cursorPos)
      input.value = newValue
      const newCursorPos = cursorPos + variable.length + 4
      input.setSelectionRange(newCursorPos, newCursorPos)
    } else {
      // Replace text between {{ and cursor
      const beforeVar = value.substring(0, lastOpenBrace + 2)
      const afterCursor = value.substring(this.currentEndPos || cursorPos)
      const newValue = beforeVar + variable + "}}" + afterCursor
      input.value = newValue
      
      // Position cursor after the inserted variable and }}
      const newCursorPos = lastOpenBrace + 2 + variable.length + 2
      input.setSelectionRange(newCursorPos, newCursorPos)
    }
    
    // Trigger input event to notify other controllers
    input.dispatchEvent(new Event("input", { bubbles: true }))
    
    this.hideDropdown()
    
    // Refocus the input
    input.focus()
  }
}
