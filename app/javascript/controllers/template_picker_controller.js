// app/javascript/controllers/template_picker_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["popover"]
  static values = { workflowId: Number }

  toggle() {
    this.popoverTarget.hidden = !this.popoverTarget.hidden
  }

  close() {
    this.popoverTarget.hidden = true
  }

  apply(event) {
    const key = event.currentTarget.dataset.templateKey
    const name = event.currentTarget.dataset.templateName

    if (!confirm(`This will replace your current steps with the "${name}" template. Continue?`)) {
      return
    }

    this.close()

    const url = `/workflows/${this.workflowIdValue}/steps/apply_template`
    const token = document.querySelector('meta[name="csrf-token"]')?.content

    fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": token,
        "Accept": "text/vnd.turbo-stream.html"
      },
      body: new URLSearchParams({ template_key: key })
    })
    .then(response => {
      if (!response.ok) throw new Error(`Template failed: ${response.status}`)
      return response.text()
    })
    .then(html => Turbo.renderStreamMessage(html))
    .catch(() => alert("Something went wrong applying the template. Please try again."))
  }

  closeOnOutsideClick = (event) => {
    if (!this.element.contains(event.target)) {
      this.close()
    }
  }

  connect() {
    document.addEventListener("click", this.closeOnOutsideClick)
  }

  disconnect() {
    document.removeEventListener("click", this.closeOnOutsideClick)
  }
}
