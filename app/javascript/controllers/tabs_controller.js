import { Controller } from "@hotwired/stimulus"

// General-purpose tab switching controller.
//
// Usage:
//   <div data-controller="tabs" data-tabs-active-value="0">
//     <button data-tabs-target="tab" data-action="click->tabs#switch">Tab 1</button>
//     <button data-tabs-target="tab" data-action="click->tabs#switch">Tab 2</button>
//     <div data-tabs-target="panel">Panel 1</div>
//     <div data-tabs-target="panel">Panel 2</div>
//   </div>
export default class extends Controller {
  static targets = ["tab", "panel"]
  static values = { active: { type: Number, default: 0 } }

  connect() {
    this.showTab(this.activeValue)
  }

  switch(event) {
    const index = this.tabTargets.indexOf(event.currentTarget)
    if (index === -1) return
    this.activeValue = index
    this.showTab(index)

    // Sync tab index to analytics filter hidden field if present
    const tabField = document.querySelector('[data-analytics-filters-target="tabField"]')
    if (tabField) tabField.value = index
  }

  showTab(index) {
    this.tabTargets.forEach((tab, i) => {
      if (i === index) {
        tab.classList.add("is-active")
        tab.classList.remove("is-inactive")
        tab.setAttribute("aria-selected", "true")
      } else {
        tab.classList.remove("is-active")
        tab.classList.add("is-inactive")
        tab.setAttribute("aria-selected", "false")
      }
    })

    this.panelTargets.forEach((panel, i) => {
      if (i === index) {
        panel.classList.remove("is-hidden")
      } else {
        panel.classList.add("is-hidden")
      }
    })
  }
}
