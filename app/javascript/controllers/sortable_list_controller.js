import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"
import { flashAlert } from "services/flash"

// Drag to reorder a list whose items carry data-sortable-id. On drop it PATCHes
// the ids in their new order to `url`, as `param`: folder_ids on the admin group
// page, featured_ids on a team page. A list rendered with a search open passes
// it as `query`, sent as `q`. An endpoint that answers with a Turbo Stream gets
// it rendered (the team page's card, whose Move buttons follow the order); the
// empty 200 the folders endpoint sends renders nothing. A save that fails puts
// the rows back in the order last saved and says so in #flash: an error (a lost
// session answers 401), no answer at all, or a redirect (lost access). Redirects
// aren't followed, so the PATCH is never sent on to a page it wasn't meant for.
export default class extends Controller {
  static values = { url: String, param: String, query: String }

  connect() {
    this.sortable = Sortable.create(this.element, {
      animation: 150,
      handle: ".cursor-move",
      ghostClass: "is-dragging",
      dataIdAttr: "data-sortable-id",
      onEnd: this.reorder.bind(this)
    })
    this.savedOrder = this.sortable.toArray()
  }

  disconnect() {
    if (this.sortable) {
      this.sortable.destroy()
      this.sortable = null
    }
  }

  reorder() {
    const ids = this.sortable.toArray()
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    const body = { [this.paramValue]: ids }
    if (this.queryValue) body.q = this.queryValue

    fetch(this.urlValue, {
      method: "PATCH",
      redirect: "manual",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken,
        "Accept": "text/vnd.turbo-stream.html, application/json"
      },
      body: JSON.stringify(body)
    })
    .then((response) => {
      // A redirect not followed comes back opaque, with ok false.
      if (!response.ok) throw new Error(`Order not saved: ${response.status}`)
      return response
    })
    .then((response) => {
      this.savedOrder = ids
      this.render(response)
    }, () => this.restore())
  }

  async render(response) {
    // Rails labels an empty `head :ok` with the first format asked for, so
    // the type alone doesn't mean there is a stream to render.
    if (!response.headers.get("Content-Type")?.includes("turbo-stream")) return

    const html = await response.text()
    if (html.trim()) Turbo.renderStreamMessage(html)
  }

  // The list may have been replaced while the save was out (a Move or Remove
  // re-rendered the card), and then there are no rows to put back, but the
  // message still says the drag didn't save.
  restore() {
    this.sortable?.sort(this.savedOrder, true)
    flashAlert("Couldn't save the new order. Try again.")
  }
}
