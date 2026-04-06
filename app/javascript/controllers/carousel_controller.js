import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["track", "leftArrow", "rightArrow"]

  connect() {
    this.trackTarget.addEventListener("scroll", this.updateArrows)
    this.updateArrows()
  }

  disconnect() {
    this.trackTarget.removeEventListener("scroll", this.updateArrows)
  }

  scrollLeft() {
    const step = this.#cardScrollStep()
    this.trackTarget.scrollBy({ left: -step, behavior: "smooth" })
  }

  scrollRight() {
    const step = this.#cardScrollStep()
    this.trackTarget.scrollBy({ left: step, behavior: "smooth" })
  }

  // Card width + gap (--space-4 = 1rem = 16px at default font size)
  #cardScrollStep() {
    const cardWidth = this.trackTarget.firstElementChild?.offsetWidth || 256
    const gap = parseFloat(getComputedStyle(this.trackTarget).columnGap) || 16
    return cardWidth + gap
  }

  updateArrows = () => {
    const { scrollLeft, scrollWidth, clientWidth } = this.trackTarget
    const atStart = scrollLeft <= 0
    const atEnd = scrollLeft + clientWidth >= scrollWidth - 1

    if (this.hasLeftArrowTarget) {
      this.leftArrowTarget.classList.toggle("is-hidden", atStart)
    }
    if (this.hasRightArrowTarget) {
      this.rightArrowTarget.classList.toggle("is-hidden", atEnd)
    }
  }
}
