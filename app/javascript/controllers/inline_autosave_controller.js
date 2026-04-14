import { Controller } from "@hotwired/stimulus"

/**
 * Inline Autosave Controller
 *
 * Simplified autosave for Turbo Frame step forms.
 * Debounces input events and calls requestSubmit() on the form.
 */
export default class extends Controller {
  static values = { delay: { type: Number, default: 2000 } }

  connect() {
    // Lexxy rich text editors fire lexxy:change instead of input events.
    // Stimulus data-action descriptors don't reliably bind to custom element
    // events loaded via Turbo Frames, so we listen programmatically.
    this.boundSchedule = this.schedule.bind(this)
    this.element.addEventListener("lexxy:change", this.boundSchedule)
  }

  schedule() {
    this.dirty = true
    clearTimeout(this.timeout)
    this.timeout = setTimeout(() => this.save(), this.delayValue)
  }

  save() {
    if (!this.dirty) return
    this.dirty = false

    // If the form is still in the DOM, use requestSubmit (Turbo-aware)
    if (this.element.isConnected) {
      this.element.requestSubmit()
      return
    }

    // Form was detached (e.g., user switched steps before debounce fired).
    // Send the saved FormData snapshot directly via fetch.
    // Use POST with _method=patch in the body (same as browser form submission).
    if (this.lastFormData && this.formAction) {
      const token = document.querySelector('meta[name="csrf-token"]')?.content
      fetch(this.formAction, {
        method: "POST",
        headers: {
          "X-CSRF-Token": token,
          "Accept": "text/vnd.turbo-stream.html"
        },
        body: this.lastFormData
      }).then(() => {
        document.dispatchEvent(new CustomEvent("health:check-needed"))
      })
    }
  }

  disconnect() {
    clearTimeout(this.timeout)
    // Snapshot form data while the form is still accessible
    this.lastFormData = new FormData(this.element)
    this.formAction = this.element.action
    this.element.removeEventListener("lexxy:change", this.boundSchedule)
    // Flush pending save using the snapshot
    this.save()
  }
}
