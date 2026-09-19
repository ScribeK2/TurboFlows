import { Controller } from "@hotwired/stimulus"

/**
 * Inline Autosave Controller
 *
 * Simplified autosave for Turbo Frame step forms.
 * Debounces input events and calls requestSubmit() on the form.
 */
export default class extends Controller {
  static values = { delay: { type: Number, default: 2000 } }

  // What the indicator says in each state. "Unsaved changes" matters as much
  // as the rest: the debounce runs for two seconds, and an indicator still
  // reading "Saved" through them is a lie.
  static STATUS = {
    dirty: ["", "Unsaved changes"],
    saving: ["builder__autosave--saving", "Saving\u2026"],
    saved: ["builder__autosave--saved", "Saved"],
    error: ["builder__autosave--error", "Not saved"]
  }

  connect() {
    // Lexxy rich text editors fire lexxy:change instead of input events.
    // Stimulus data-action descriptors don't reliably bind to custom element
    // events loaded via Turbo Frames, so we listen programmatically.
    this.boundSchedule = this.schedule.bind(this)
    this.element.addEventListener("lexxy:change", this.boundSchedule)

    this.boundSubmitEnded = this.submitEnded.bind(this)
    this.element.addEventListener("turbo:submit-end", this.boundSubmitEnded)

    // Held from here, not looked up when it is needed: by the time the
    // disconnect flush below answers, this form is detached and cannot reach
    // its own frame any more.
    this.statusElement = this.element.closest("turbo-frame")?.querySelector("[data-autosave-status]")
  }

  schedule() {
    this.dirty = true
    this.setStatus("dirty")
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
        // requestSubmit renders a stream answer for free; this path has to do
        // it by hand or the answer is lost. EVERY answer, not only a refusal:
        // a save that heals a stale panel succeeds AND carries a notice
        // saying a connection was removed elsewhere, and that used to be
        // dropped here with nothing shown. A stream aimed at an element this
        // page no longer has - the panel has already been replaced - is a
        // no-op, so rendering the rest costs nothing.
        if (response.headers.get("Content-Type")?.includes("turbo-stream")) {
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
  // flight.
  //
  // ONE promise however many saves pile up: a save that supersedes another
  // aborts it, and what a waiter cares about is the last one. The timer is a
  // floor under a submit that never reports an end (an abort nothing
  // followed), so nothing that waits on this can wait for ever.
  trackSubmission() {
    this.setStatus("saving")
    clearTimeout(this.inFlightTimer)
    if (!this.inFlight) this.inFlight = new Promise(resolve => { this.resolveInFlight = resolve })
    this.inFlightTimer = setTimeout(() => this.settleInFlight(), 8000)
  }

  // Turbo dispatches turbo:submit-end from a `finally`, so a submission ABORTED
  // because a newer save superseded it fires one too - with no `success` key,
  // since it never got a result (FormSubmission#requestFinished). That is not
  // the end of anything: the save that replaced it is still on its way.
  submitEnded(event) {
    if (!("success" in event.detail)) return

    this.setStatus(event.detail.success ? "saved" : "error")
    this.settleInFlight()
  }

  // Skipped once the element is off the page: a flush sent as the panel closes
  // answers after the NEXT step's panel has rendered its own, and that one is
  // not describing this save.
  setStatus(state) {
    const element = this.statusElement
    if (!element?.isConnected) return

    const [modifier, text] = this.constructor.STATUS[state]
    element.className = ["builder__autosave", modifier].filter(Boolean).join(" ")
    element.textContent = text
  }

  settleInFlight() {
    clearTimeout(this.inFlightTimer)
    const resolve = this.resolveInFlight
    this.inFlight = null
    this.resolveInFlight = null
    resolve?.()
  }

  disconnect() {
    clearTimeout(this.timeout)
    // Snapshot form data while the form is still accessible
    this.lastFormData = new FormData(this.element)
    this.formAction = this.element.action
    this.element.removeEventListener("lexxy:change", this.boundSchedule)
    this.element.removeEventListener("turbo:submit-end", this.boundSubmitEnded)
    // Whoever was waiting on this form is released: it is gone, and the flush
    // below goes out by fetch, which nothing here tracks.
    this.settleInFlight()
    // Flush pending save using the snapshot
    this.save()
  }
}
