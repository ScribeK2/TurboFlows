import { Controller } from "@hotwired/stimulus"

// Coordinates multiple dialog controllers to enforce single-open behavior.
// Attach to a parent element (e.g., <nav>) and declare outlets for each dialog controller.
//
// Usage:
//   <nav data-controller="dialog-manager"
//        data-dialog-manager-nav-menu-outlet="[data-controller='nav-menu']"
//        data-dialog-manager-nav-search-outlet="[data-controller='nav-search']"
//        data-action="dialog:show->dialog-manager#closeOthers">
export default class extends Controller {
  static outlets = ["nav-menu", "nav-search"]

  closeOthers(event) {
    const source = event.target

    if (this.hasNavMenuOutlet && !this.navMenuOutlet.element.contains(source)) {
      this.navMenuOutlet.close()
    }

    if (this.hasNavSearchOutlet && !this.navSearchOutlet.element.contains(source)) {
      this.navSearchOutlet.close()
    }
  }
}
