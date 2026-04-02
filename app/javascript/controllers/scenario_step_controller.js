import { Controller } from "@hotwired/stimulus"

// Handles scenario step interactivity:
// - Auto-advance on radio selection (yes/no, multiple choice)
// - Auto-focus first input on connect
// - Keyboard shortcuts (Enter = submit, Esc = cancel)
// - Continue button disabled until input provided
// - Spinner + "Processing..." on submit (prevents double-submit)
// - ARIA live region announcements
//
// Usage:
//   data-controller="scenario-step"
//   data-scenario-step-auto-advance-value="true"
//   data-scenario-step-step-info-value="Step 3: Ask customer name"
//   data-scenario-step-cancel-url-value="/workflows/1"
export default class extends Controller {
  static targets = ["form", "submit", "cancel", "input", "announce"]
  static values = {
    autoAdvance: { type: Boolean, default: false },
    stepInfo: { type: String, default: "" },
    cancelUrl: { type: String, default: "" }
  }

  connect() {
    this.autoAdvanceTimer = null
    this.submitted = false

    // Auto-focus first input
    if (this.hasInputTarget) {
      // Use requestAnimationFrame to ensure DOM is ready
      requestAnimationFrame(() => {
        this.inputTarget.focus()
      })
    }

    // Dynamic page title
    if (this.hasStepInfoValue && this.stepInfoValue) {
      document.title = `Step ${this.stepInfoValue} — TurboFlows`
    }

    // ARIA announcement
    if (this.hasAnnounceTarget && this.stepInfoValue) {
      this.announceTarget.textContent = this.stepInfoValue
    }

    // Keyboard shortcuts
    this.handleKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.handleKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleKeydown)
    if (this.autoAdvanceTimer) {
      clearTimeout(this.autoAdvanceTimer)
    }
  }

  handleKeydown(event) {
    // Don't intercept when typing in inputs (except radio/checkbox)
    const tag = event.target.tagName
    const type = event.target.type
    if (tag === "TEXTAREA" || tag === "SELECT") return
    if (tag === "INPUT" && type !== "radio" && type !== "checkbox") return

    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.submitForm()
    } else if (event.key === "Escape") {
      event.preventDefault()
      this.cancelScenario()
    }
  }

  // Called when any input value changes (radio, text, select, textarea)
  inputChanged() {
    if (this.hasSubmitTarget) {
      this.submitTarget.disabled = false
      this.submitTarget.classList.remove("is-disabled")
    }

    // Auto-advance for radio buttons (yes/no, multiple choice)
    if (this.autoAdvanceValue) {
      if (this.autoAdvanceTimer) {
        clearTimeout(this.autoAdvanceTimer)
      }
      this.autoAdvanceTimer = setTimeout(() => {
        this.submitForm()
      }, 300)
    }
  }

  submitForm() {
    if (this.submitted) return
    if (!this.hasFormTarget) return

    // Check if form was already submitted (persists across Stimulus reconnection via DOM attribute)
    if (this.formTarget.dataset.submitting === "true") return

    // Check if submit button is disabled (no input yet)
    if (this.hasSubmitTarget && this.submitTarget.disabled) return

    // Cancel any pending auto-advance timer to prevent double-submit
    if (this.autoAdvanceTimer) {
      clearTimeout(this.autoAdvanceTimer)
      this.autoAdvanceTimer = null
    }

    this.submitted = true
    this.formTarget.dataset.submitting = "true"

    // Fade out content before submitting
    const content = this.element.querySelector(".scenario-content-layout") || this.formTarget
    content.animate([
      { opacity: 1 },
      { opacity: 0 }
    ], { duration: 120, easing: "ease-out", fill: "forwards" })

    // Show spinner on submit button
    // Trust boundary: static SVG spinner markup only, no user data interpolated.
    if (this.hasSubmitTarget) {
      this.submitTarget.disabled = true
      this.submitTarget.innerHTML = `
        <svg class="btn__spinner" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
          <circle class="btn__spinner-track" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
          <path class="btn__spinner-fill" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
        </svg>
        Processing...
      `
      this.submitTarget.classList.add("is-disabled")
    }

    this.formTarget.requestSubmit()
  }

  cancelScenario() {
    if (!this.cancelUrlValue) return

    // Trigger Turbo confirmation if the cancel link has one
    if (this.hasCancelTarget) {
      this.cancelTarget.click()
    } else {
      if (confirm("Are you sure you want to cancel? Your scenario progress will be lost.")) {
        window.location.href = this.cancelUrlValue
      }
    }
  }
}
