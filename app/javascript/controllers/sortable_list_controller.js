import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

// Drag to reorder a list whose items carry data-sortable-id. On drop it PATCHes
// the ids in their new order to `url`, as `param`: folder_ids on the admin group
// page, featured_ids on a team page.
export default class extends Controller {
  static values = { url: String, param: String }

  connect() {
    this.sortable = Sortable.create(this.element, {
      animation: 150,
      handle: ".cursor-move",
      ghostClass: "is-dragging",
      onEnd: this.reorder.bind(this)
    })
  }

  disconnect() {
    if (this.sortable) {
      this.sortable.destroy()
    }
  }

  reorder() {
    const ids = Array.from(this.element.children).map((item) => item.dataset.sortableId)
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    fetch(this.urlValue, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken,
        "Accept": "application/json"
      },
      body: JSON.stringify({ [this.paramValue]: ids })
    })
  }
}
