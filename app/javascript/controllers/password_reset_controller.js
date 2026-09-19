import { Controller } from "@hotwired/stimulus"

// Generates a temporary password for one user and shows it once, in a native
// <dialog>: confirm first, then the result. Replaces the users table's
// confirm()/alert() flow. The password only ever arrives in this JSON response
// (Admin::UsersController#reset_password sets Cache-Control: no-store), and is
// forgotten when the dialog closes.
export default class extends Controller {
  static targets = [
    "dialog", "confirmStep", "resultStep", "confirmActions", "resultActions",
    "password", "error", "generateButton", "copyButton"
  ]
  static values = { url: String }

  connect() {
    this.beforeCache = this.beforeCache.bind(this)
    document.addEventListener("turbo:before-cache", this.beforeCache)
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.beforeCache)
  }

  open() {
    this.showStep("confirm")
    this.clearError()
    this.dialogTarget.showModal()
  }

  async generate() {
    this.generateButtonTarget.disabled = true
    this.clearError()

    try {
      const token = document.querySelector('meta[name="csrf-token"]')?.content
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: { "X-CSRF-Token": token, "Accept": "application/json" },
        credentials: "same-origin"
      })
      const data = await response.json()
      if (!response.ok || !data.success) throw new Error(data.error || "The password could not be reset.")

      this.passwordTarget.textContent = data.password
      this.showStep("result")
    } catch (error) {
      this.errorTarget.textContent = error.message
    } finally {
      this.generateButtonTarget.disabled = false
    }
  }

  // Emptying it is what hides it (.form-error:empty). NOT .is-hidden, which is
  // display: none - this carries role="alert", and a live region has to be in
  // the accessibility tree before its text arrives.
  clearError() {
    this.errorTarget.textContent = ""
  }

  async copy() {
    const password = this.passwordTarget.textContent
    if (!password) return

    try {
      await navigator.clipboard.writeText(password)
      this.copyButtonTarget.textContent = "Copied"
    } catch {
      this.copyButtonTarget.textContent = "Copy failed — select it"
    }
    setTimeout(() => { this.copyButtonTarget.textContent = "Copy Password" }, 2000)
  }

  close() {
    this.dialogTarget.close()
  }

  // A click whose target is the <dialog> itself landed on the backdrop.
  backdropClose(event) {
    if (event.target === this.dialogTarget) this.close()
  }

  forget() {
    this.passwordTarget.textContent = ""
    this.showStep("confirm")
  }

  // Turbo snapshots the page on the way out. An open dialog would come back on
  // Back/Forward as a bare <dialog open> — no backdrop, not modal — and the
  // snapshot would keep the password in it. forget() is called directly: the
  // dialog's close event is a queued task, and nothing orders it ahead of the
  // tick Turbo waits before cloning the page.
  beforeCache() {
    this.forget()
    if (this.dialogTarget.open) this.dialogTarget.close()
  }

  showStep(step) {
    const confirming = step === "confirm"
    this.confirmStepTarget.classList.toggle("is-hidden", !confirming)
    this.confirmActionsTarget.classList.toggle("is-hidden", !confirming)
    this.resultStepTarget.classList.toggle("is-hidden", confirming)
    this.resultActionsTarget.classList.toggle("is-hidden", confirming)
  }
}
