import { Controller } from "@hotwired/stimulus"

// Client-side filter for the Player workflow index.
// Filters cards by matching query against title and description data attributes.
export default class extends Controller {
  static targets = ["input", "card", "empty"]

  filter() {
    const query = this.inputTarget.value.trim().toLowerCase()
    let visible = 0

    this.cardTargets.forEach(card => {
      const title = (card.dataset.title || "").toLowerCase()
      const desc = (card.dataset.description || "").toLowerCase()
      const match = query === "" || title.includes(query) || desc.includes(query)
      card.style.display = match ? "" : "none"
      if (match) visible++
    })

    if (this.hasEmptyTarget) {
      this.emptyTarget.hidden = visible > 0
    }
  }
}
