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
    const cardWidth = this.trackTarget.firstElementChild?.offsetWidth || 256
    this.trackTarget.scrollBy({ left: -cardWidth - 16, behavior: "smooth" })
  }

  scrollRight() {
    const cardWidth = this.trackTarget.firstElementChild?.offsetWidth || 256
    this.trackTarget.scrollBy({ left: cardWidth + 16, behavior: "smooth" })
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
