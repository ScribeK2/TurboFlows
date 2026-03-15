import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["titleInput", "counter", "submitButton"]
  static values = { max: { type: Number, default: 100 } }

  connect() {
    this.validate()
  }

  validate() {
    const title = this.titleInputTarget.value
    const length = title.length
    const max = this.maxValue

    // Update character counter
    this.counterTarget.textContent = `${length}/${max} characters`

    // Amber color when near limit (>80%)
    if (length > max * 0.8) {
      this.counterTarget.classList.add("status--warning")
      this.counterTarget.classList.remove("status--muted")
    } else {
      this.counterTarget.classList.remove("status--warning")
      this.counterTarget.classList.add("status--muted")
    }

    // Disable submit when empty or still default
    const trimmed = title.trim()
    const isInvalid = trimmed === "" || trimmed === "Untitled Workflow"
    this.submitButtonTarget.disabled = isInvalid
  }
}
