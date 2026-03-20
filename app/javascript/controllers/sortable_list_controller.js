import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

export default class extends Controller {
  static values = {
    url: String,
    handle: { type: String, default: ".drag-handle" }
  }

  connect() {
    this.sortable = Sortable.create(this.element, {
      handle: this.handleValue,
      animation: 150,
      ghostClass: "step-card--ghost",
      onEnd: this.handleReorder.bind(this)
    })
  }

  disconnect() {
    this.sortable?.destroy()
  }

  async handleReorder(event) {
    const stepId = event.item.dataset.stepId
    if (!stepId) return

    const url = this.urlValue.replace(":id", stepId)
    const token = document.querySelector('meta[name="csrf-token"]')?.content

    const response = await fetch(url, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": token,
        "Accept": "text/vnd.turbo-stream.html"
      },
      body: JSON.stringify({ position: event.newIndex })
    })

    if (!response.ok) {
      console.error("Reorder failed:", response.status)
    }
  }
}
