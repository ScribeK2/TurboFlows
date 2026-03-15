import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["select", "search", "options", "option"]
  static values = {
    placeholder: { type: String, default: "-- Select step --" }
  }

  connect() {
    this.setupSearchable()
    this.selectedOption = null
  }

  disconnect() {
    // Cleanup if needed
  }

  setupSearchable() {
    if (!this.hasSelectTarget) return

    const select = this.selectTarget
    
    // Get current value
    const currentValue = select.value
    
    // Check if already set up
    if (this.element.querySelector(".searchable-dropdown-search")) {
      return // Already set up
    }
    
    // Ensure element is relative positioned
    if (!this.element.classList.contains("relative")) {
      this.element.classList.add("relative")
    }
    
    // Create search input
    const searchInput = document.createElement("input")
    searchInput.type = "text"
    searchInput.className = "searchable-dropdown-search form-input"
    searchInput.placeholder = this.placeholderValue
    searchInput.setAttribute("data-searchable-dropdown-target", "search")
    searchInput.setAttribute("autocomplete", "off")
    
    // Create dropdown arrow
    const arrow = document.createElement("div")
    arrow.className = "searchable-dropdown-arrow"
    arrow.innerHTML = `<svg class="dropdown-arrow-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"></path>
    </svg>`
    
    // Create options container
    const optionsContainer = document.createElement("div")
    optionsContainer.className = "searchable-dropdown-options is-hidden"
    optionsContainer.setAttribute("data-searchable-dropdown-target", "options")
    
    // Insert search input before select
    select.parentElement.insertBefore(searchInput, select)
    select.parentElement.insertBefore(arrow, select)
    select.parentElement.appendChild(optionsContainer)
    
    // Hide original select
    select.classList.add("is-hidden")
    
    // Build options from select
    this.buildOptions()
    
    // Set initial value
    if (currentValue) {
      const option = select.querySelector(`option[value="${this.escapeHtml(currentValue)}"]`)
      if (option) {
        searchInput.value = option.textContent.trim()
        this.selectedOption = { value: option.value, text: option.textContent.trim() }
      }
    }
    
    // Set up event listeners
    this.setupEventListeners()
  }

  setupEventListeners() {
    if (!this.hasSearchTarget || !this.hasOptionsTarget) return

    const search = this.searchTarget
    const options = this.optionsTarget
    const select = this.selectTarget

    // Search input events
    search.addEventListener("input", (e) => this.handleSearch(e))
    search.addEventListener("focus", () => this.showOptions())
    search.addEventListener("blur", () => {
      // Delay to allow option click
      setTimeout(() => {
        if (!options.matches(":hover") && !search.matches(":hover")) {
          this.hideOptions()
        }
      }, 200)
    })
    
    // Click outside to close
    document.addEventListener("click", (e) => {
      if (!this.element.contains(e.target)) {
        this.hideOptions()
      }
    })
    
    // Prevent form submission on Enter in search
    search.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault()
        const firstOption = options.querySelector(".searchable-option:not(.is-hidden)")
        if (firstOption) {
          this.selectOption(firstOption.dataset.value, firstOption.textContent.trim())
        }
      } else if (e.key === "Escape") {
        this.hideOptions()
      } else if (e.key === "ArrowDown") {
        e.preventDefault()
        this.highlightNextOption()
      } else if (e.key === "ArrowUp") {
        e.preventDefault()
        this.highlightPreviousOption()
      }
    })
  }

  handleSearch(event) {
    const query = event.target.value.toLowerCase().trim()
    const options = this.optionTargets
    
    options.forEach(option => {
      const text = option.textContent.toLowerCase().trim()
      if (text.includes(query) || query === "") {
        option.classList.remove("is-hidden")
      } else {
        option.classList.add("is-hidden")
      }
    })
    
    // Show options if search is active
    if (query) {
      this.showOptions()
    }
    
    // Clear selection if search changed
    this.selectedOption = null
    if (this.hasSelectTarget) {
      this.selectTarget.value = ""
    }
  }

  showOptions() {
    if (this.hasOptionsTarget) {
      this.optionsTarget.classList.remove("is-hidden")
    }
  }

  hideOptions() {
    if (this.hasOptionsTarget) {
      this.optionsTarget.classList.add("is-hidden")
    }
  }

  selectOption(value, text) {
    if (this.hasSearchTarget) {
      this.searchTarget.value = text
    }
    
    if (this.hasSelectTarget) {
      this.selectTarget.value = value
      // Trigger change event for other listeners
      this.selectTarget.dispatchEvent(new Event("change", { bubbles: true }))
    }
    
    this.selectedOption = { value, text }
    this.hideOptions()
    
    // Clear search
    if (this.hasSearchTarget) {
      this.handleSearch({ target: { value: "" } })
      this.searchTarget.value = text
    }
  }

  highlightNextOption() {
    const visibleOptions = Array.from(this.optionTargets).filter(opt => !opt.classList.contains("hidden"))
    const currentIndex = visibleOptions.findIndex(opt => opt.classList.contains("is-highlighted"))
    
    visibleOptions.forEach(opt => opt.classList.remove("is-highlighted"))
    
    if (currentIndex < visibleOptions.length - 1) {
      visibleOptions[currentIndex + 1].classList.add("is-highlighted")
      visibleOptions[currentIndex + 1].scrollIntoView({ block: "nearest" })
    } else if (visibleOptions.length > 0) {
      visibleOptions[0].classList.add("is-highlighted")
      visibleOptions[0].scrollIntoView({ block: "nearest" })
    }
  }

  highlightPreviousOption() {
    const visibleOptions = Array.from(this.optionTargets).filter(opt => !opt.classList.contains("hidden"))
    const currentIndex = visibleOptions.findIndex(opt => opt.classList.contains("is-highlighted"))
    
    visibleOptions.forEach(opt => opt.classList.remove("is-highlighted"))
    
    if (currentIndex > 0) {
      visibleOptions[currentIndex - 1].classList.add("is-highlighted")
      visibleOptions[currentIndex - 1].scrollIntoView({ block: "nearest" })
    } else if (visibleOptions.length > 0) {
      visibleOptions[visibleOptions.length - 1].classList.add("is-highlighted")
      visibleOptions[visibleOptions.length - 1].scrollIntoView({ block: "nearest" })
    }
  }

  buildOptions() {
    if (!this.hasSelectTarget || !this.hasOptionsTarget) return

    const select = this.selectTarget
    const optionsContainer = this.optionsTarget
    
    // Clear existing options
    optionsContainer.innerHTML = ""
    
    // Build options from select element
    Array.from(select.options).forEach(option => {
      if (option.value === "") {
        // Skip empty option (placeholder)
        return
      }
      
      const optionElement = document.createElement("div")
      optionElement.className = "searchable-option"
      optionElement.textContent = option.textContent.trim()
      optionElement.dataset.value = option.value
      optionElement.setAttribute("data-searchable-dropdown-target", "option")
      
      optionElement.addEventListener("click", () => {
        this.selectOption(option.value, option.textContent.trim())
      })
      
      optionsContainer.appendChild(optionElement)
    })
  }

  refresh() {
    // Rebuild options when select options change
    this.buildOptions()
    
    // Update search input value if select has a value
    if (this.hasSelectTarget && this.selectTarget.value && this.hasSearchTarget) {
      const selectedOption = this.selectTarget.querySelector(`option[value="${this.escapeHtml(this.selectTarget.value)}"]`)
      if (selectedOption) {
        this.searchTarget.value = selectedOption.textContent.trim()
        this.selectedOption = { value: selectedOption.value, text: selectedOption.textContent.trim() }
      }
    }
  }

  // Public method to refresh dropdown (called from workflow_builder)
  refreshDropdown() {
    this.refresh()
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}

