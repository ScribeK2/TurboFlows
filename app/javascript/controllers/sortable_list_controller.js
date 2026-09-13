import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

// Drag to reorder a list whose items carry data-sortable-id. On drop it PATCHes
// the ids in their new order to `url`, as `param`: folder_ids on the admin group
// page, featured_ids on a team page. A list rendered with a search open passes
// it as `query`, sent as `q`. An endpoint that answers with a Turbo Stream gets
// it rendered (the team page's card, whose Move buttons follow the order); the
// empty 200 the folders endpoint sends renders nothing.
export default class extends Controller {
  static values = { url: String, param: String, query: String }

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
    const body = { [this.paramValue]: ids }
    if (this.queryValue) body.q = this.queryValue

    fetch(this.urlValue, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken,
        "Accept": "text/vnd.turbo-stream.html, application/json"
      },
      body: JSON.stringify(body)
    })
    .then(async (response) => {
      // Rails labels an empty `head :ok` with the first format asked for, so
      // the type alone doesn't mean there is a stream to render.
      if (!response.headers.get("Content-Type")?.includes("turbo-stream")) return

      const html = await response.text()
      if (html.trim()) Turbo.renderStreamMessage(html)
    })
  }
}
