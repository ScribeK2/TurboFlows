import { Controller } from "@hotwired/stimulus"

// Controller for highlighting fields with errors and scrolling to first error
// Attach to forms or error containers to enable automatic error field highlighting
export default class extends Controller {
  static targets = ["errorContainer"]

  connect() {
    // On page load, check for errors and scroll to first one
    this.highlightErrorFields()
    this.scrollToFirstError()
  }

  highlightErrorFields() {
    // Find all fields marked with data-error-field attribute
    const errorFields = this.element.querySelectorAll("[data-error-field]")

    errorFields.forEach(field => {
      const fieldName = field.dataset.errorField
      // Check if there's an error message for this field
      if (this.hasErrorForField(fieldName)) {
        this.applyErrorStyling(field)
      }
    })
  }

  hasErrorForField(fieldName) {
    // Check error container for field-specific errors
    if (!this.hasErrorContainerTarget) return false

    const errorMessages = this.errorContainerTarget.textContent.toLowerCase()
    return errorMessages.includes(fieldName.toLowerCase())
  }

  applyErrorStyling(field) {
    // Add error styling
    field.classList.add("is-invalid")

    // Add error indicator icon if input field
    if (field.tagName === "INPUT" || field.tagName === "TEXTAREA") {
      this.addErrorIcon(field)
    }
  }

  addErrorIcon(field) {
    const wrapper = field.parentElement
    if (!wrapper || wrapper.classList.contains("error-icon-added")) return

    wrapper.classList.add("error-icon-wrapper", "error-icon-added")

    // Trust boundary: static SVG error icon only, no user data interpolated.
    const icon = document.createElement("div")
    icon.className = "error-icon"
    icon.innerHTML = `
      <svg class="error-icon__svg" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
      </svg>
    `
    wrapper.appendChild(icon)

    // CSS handles padding for the icon via .is-invalid or error-icon-wrapper styles
  }

  scrollToFirstError() {
    // First try to scroll to an error field
    const firstErrorField = this.element.querySelector(
      "[data-error-field].is-invalid"
    )

    if (firstErrorField) {
      setTimeout(() => {
        firstErrorField.scrollIntoView({ behavior: "smooth", block: "center" })
        firstErrorField.focus()
      }, 100)
      return
    }

    // Fallback: scroll to error container
    if (this.hasErrorContainerTarget) {
      setTimeout(() => {
        this.errorContainerTarget.scrollIntoView({ behavior: "smooth", block: "center" })
      }, 100)
    }
  }

  // Called when form is submitted with errors (can be triggered manually)
  refresh() {
    this.highlightErrorFields()
    this.scrollToFirstError()
  }
}
