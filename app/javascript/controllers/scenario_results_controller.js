import { Controller } from "@hotwired/stimulus"

// Handles expand/collapse of individual execution path items on the scenario results page.
//
// Usage:
//   <div data-controller="scenario-results">
//     <button data-action="click->scenario-results#expandAll">Expand All</button>
//     <button data-action="click->scenario-results#collapseAll">Collapse All</button>
//     <div data-scenario-results-target="item">
//       <button data-action="click->scenario-results#toggle">
//         <svg data-scenario-results-target="toggleIcon">...</svg>
//       </button>
//       <div data-scenario-results-target="details" class="hidden">...</div>
//     </div>
//   </div>
export default class extends Controller {
  static targets = ["details", "toggleIcon", "item"]

  toggle(event) {
    const item = event.currentTarget.closest("[data-scenario-results-target='item']")
    if (!item) return

    const index = this.itemTargets.indexOf(item)
    if (index === -1) return

    const details = this.detailsTargets[index]
    const icon = this.toggleIconTargets[index]
    if (!details) return

    const isHidden = details.classList.contains("is-hidden")
    details.classList.toggle("is-hidden")

    if (icon) {
      icon.style.transform = isHidden ? "rotate(90deg)" : ""
    }

    // Update aria-expanded on the toggle button
    event.currentTarget.setAttribute("aria-expanded", isHidden ? "true" : "false")
  }

  expandAll() {
    this.detailsTargets.forEach((details, index) => {
      details.classList.remove("is-hidden")
      const icon = this.toggleIconTargets[index]
      if (icon) icon.style.transform = "rotate(90deg)"
    })

    this.element.querySelectorAll("[aria-expanded]").forEach(el => {
      el.setAttribute("aria-expanded", "true")
    })
  }

  collapseAll() {
    this.detailsTargets.forEach((details, index) => {
      details.classList.add("is-hidden")
      const icon = this.toggleIconTargets[index]
      if (icon) icon.style.transform = ""
    })

    this.element.querySelectorAll("[aria-expanded]").forEach(el => {
      el.setAttribute("aria-expanded", "false")
    })
  }
}
