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
      this.trackSubmission()
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
      }).then(async (response) => {
        // A refused save answers with a Turbo Stream saying why (a save that
        // lost a race to another tab updates #flash). requestSubmit renders
        // that for free; this path has to, or the refusal is silent.
        if (!response.ok && response.headers.get("Content-Type")?.includes("turbo-stream")) {
          const html = await response.text()
          if (html.trim()) Turbo.renderStreamMessage(html)
        }
        document.dispatchEvent(new CustomEvent("health:check-needed"))
      })
    }
  }

  // Saves now if anything is waiting on the debounce, and resolves once no save
  // of this form is in flight - including one that was already on its way.
  //
  // For whoever is about to act on what the SERVER believes about this step.
  // A grow is the case: the panel's doors are server-rendered, so inside the
  // debounce they still show the step as it was, and a grow that lands before
  // this save writes a connection for a door the step is about to stop having
  // (step_list_controller#growAfterPendingSave).
  flush() {
    if (this.dirty && this.element.isConnected) {
      clearTimeout(this.timeout)
      this.save()
    }
    return this.inFlight || Promise.resolve()
  }

  // Started here, not on turbo:submit-start: Turbo dispatches that a tick or
  // two after requestSubmit(), and a flush() in between would see nothing in
  // flight. The timer is a floor under a submit that never reports an end, so
  // nothing that waits on this can wait for ever.
  trackSubmission() {
    const form = this.element
    this.inFlight = new Promise(resolve => {
      const done = () => {
        clearTimeout(timer)
        form.removeEventListener("turbo:submit-end", done)
        this.inFlight = null
        resolve()
      }
      const timer = setTimeout(done, 8000)
      form.addEventListener("turbo:submit-end", done)
    })
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
