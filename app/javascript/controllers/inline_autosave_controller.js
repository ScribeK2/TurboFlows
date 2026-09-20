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
    this.boundLexxyChange = this.lexxyChanged.bind(this)
    this.element.addEventListener("lexxy:change", this.boundLexxyChange)

    this.boundSubmitEnded = this.submitEnded.bind(this)
    this.element.addEventListener("turbo:submit-end", this.boundSubmitEnded)

    // What the server rendered into each named input, captured before the author
    // can change anything, and which fields they then actually touch. The panel
    // submits the WHOLE step on every change, so without these two the server
    // cannot tell an edit from a seconds-old copy of someone else's field.
    this.renderedValues = new Map()
    this.dirtyFields = new Set()
    this.namedInputs().forEach(input => this.renderedValues.set(input.name, input.value))

    this.boundMarkDirty = this.markDirty.bind(this)
    this.element.addEventListener("input", this.boundMarkDirty)
    this.element.addEventListener("change", this.boundMarkDirty)

    // Held from here, not looked up when it is needed: by the time the
    // disconnect flush below answers, this form is detached and cannot reach
    // its own frame any more.
    this.statusElement = this.element.closest("turbo-frame")?.querySelector("[data-autosave-status]")
  }

  // Lexxy does not fire the input events markDirty listens for, so its change
  // has to do both jobs.
  lexxyChanged(event) {
    this.markDirty(event)
    this.schedule()
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
      // The detached path below does this in disconnect() instead, because its
      // FormData snapshot is taken there.
      this.writeDirtyState()
      this.rememberSentValues()
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

  // Every input this form submits under step[...], minus the two keys this
  // mechanism adds itself and transitions_json, which has its own staleness
  // protocol (rendered/minted) and is deliberately left out of this one.
  namedInputs() {
    return Array.from(this.element.elements).filter(input => this.tracked(input.name))
  }

  tracked(name) {
    return Boolean(name) &&
      name.startsWith("step[") &&
      !name.startsWith("step[dirty_fields") &&
      !name.startsWith("step[rendered") &&
      name !== "step[transitions_json]"
  }

  // step[options][][label] -> options. The server keys both dirty fields and
  // rendered values by attribute name, not by the full input name.
  fieldNameOf(input) {
    return input.name.match(/^step\[([^\]]+)\]/)?.[1] ?? null
  }

  markDirty(event) {
    const named = this.namedElementFor(event.target)
    if (!named) return

    const field = this.fieldNameOf(named)
    if (field) this.dirtyFields.add(field)
  }

  // A plain input is itself. Rich text arrives here too: <lexxy-editor> is
  // form-associated and carries the same name= a plain input would, and an
  // `input` event raised inside it is retargeted to that host as it leaves the
  // shadow boundary — so the FIRST branch is what fires for typing. Verified by
  // mutation: disabling it fails three of the field-scoped system tests.
  //
  // The closest() walk below is a guard for an event that is NOT retargeted
  // (a toolbar action, say). Mutation shows nothing in the suite reaches it, so
  // treat it as unproven rather than as covered — it is two lines against a
  // third-party custom element's internals, which is why it stays.
  namedElementFor(target) {
    if (this.tracked(target?.name)) return target

    const editor = target?.closest?.("lexxy-editor")
    return this.tracked(editor?.name) ? editor : null
  }

  // Written into the form itself rather than appended to a FormData, so the
  // disconnect flush - which snapshots the form - carries them too.
  writeDirtyState() {
    this.element.querySelectorAll("[data-autosave-generated]").forEach(node => node.remove())

    // The empty sentinel goes out ALWAYS, so this panel's saves always DECLARE
    // which fields they touched. Without it a panel that marked nothing dirty
    // sends no dirty_fields key at all, the server's absent-key fallback writes
    // everything, and the whole mechanism silently reverts to clobbering with
    // every test still green - which is exactly what two mutation checks caught.
    // An absent key now means only "a client older than this code".
    this.appendHidden("step[dirty_fields][]", "")

    this.dirtyFields.forEach(field => {
      this.appendHidden("step[dirty_fields][]", field)
      const rendered = this.renderedValueFor(field)
      if (rendered !== undefined) this.appendHidden(`step[rendered][${field}]`, rendered)
    })
  }

  // Only meaningful where a field is one input. `options` is many, and a
  // checkbox is two (Rails renders a hidden "0" beside it), so those send no
  // rendered value and the server simply does not conflict-check them.
  singleInputFor(field) {
    const inputs = this.namedInputs().filter(input => this.fieldNameOf(input) === field)
    return inputs.length === 1 ? inputs[0] : null
  }

  renderedValueFor(field) {
    // A rich-text field's baseline is rendered by the server (see
    // steps/_panel_edit): the Lexxy editor is form-associated and holds its own
    // normalisation of the body, not what the column stores, so snapshotting it
    // would conflict with itself on the first edit. Leave that one alone.
    if (this.element.querySelector(`input[data-autosave-rendered][name="step[rendered][${field}]"]`)) {
      return undefined
    }

    const input = this.singleInputFor(field)
    return input ? this.renderedValues.get(input.name) : undefined
  }

  rememberSentValues() {
    this.sentValues = new Map()
    this.dirtyFields.forEach(field => {
      const input = this.singleInputFor(field)
      if (input) this.sentValues.set(input.name, input.value)
    })
  }

  // A save that landed is what the server now holds, so it becomes the new
  // rendered baseline. Without this the author's NEXT edit is compared against
  // the value their own last save replaced, and every second edit of a field is
  // refused as a conflict with themselves.
  adoptSentValues() {
    this.sentValues?.forEach((value, name) => this.renderedValues.set(name, value))
    this.sentValues = null
    this.dirtyFields.clear()
  }

  appendHidden(name, value) {
    const input = document.createElement("input")
    input.type = "hidden"
    input.name = name
    input.value = value
    input.setAttribute("data-autosave-generated", "")
    this.element.appendChild(input)
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
    if (event.detail.success) this.adoptSentValues()
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
    // BEFORE the snapshot, not after: save() writes the dirty state too, but by
    // the time it runs on this path the FormData has already been taken and the
    // flush would carry none of it. That flush is the save most likely to be
    // racing someone - it fires when the author switches steps mid-debounce.
    if (this.dirty) this.writeDirtyState()
    // Snapshot form data while the form is still accessible
    this.lastFormData = new FormData(this.element)
    this.formAction = this.element.action
    this.element.removeEventListener("lexxy:change", this.boundLexxyChange)
    this.element.removeEventListener("turbo:submit-end", this.boundSubmitEnded)
    this.element.removeEventListener("input", this.boundMarkDirty)
    this.element.removeEventListener("change", this.boundMarkDirty)
    // Whoever was waiting on this form is released: it is gone, and the flush
    // below goes out by fetch, which nothing here tracks.
    this.settleInFlight()
    // Flush pending save using the snapshot
    this.save()
  }
}
