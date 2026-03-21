import { Controller } from "@hotwired/stimulus"

// Auto-submits its form element on connect.
// Used as an invisible fallback for sub-flow steps that should
// have been auto-advanced by the controller but weren't.
export default class extends Controller {
  connect() {
    this.element.requestSubmit()
  }
}
