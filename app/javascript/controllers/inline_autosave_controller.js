import { Controller } from "@hotwired/stimulus"

/**
 * Inline Autosave Controller
 *
 * Simplified autosave for Turbo Frame step forms.
 * Debounces input events and calls requestSubmit() on the form.
 */
export default class extends Controller {
  static values = { delay: { type: Number, default: 2000 } }

  schedule() {
    clearTimeout(this.timeout)
    this.timeout = setTimeout(() => this.element.requestSubmit(), this.delayValue)
  }

  disconnect() {
    clearTimeout(this.timeout)
  }
}
