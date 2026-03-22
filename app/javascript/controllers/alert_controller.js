import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    duration: { type: Number, default: 5000 }
  }

  static targets = ["progress"]

  connect() {
    this.element.animate([
      { transform: "translateX(120%)", opacity: 0 },
      { transform: "translateX(-4%)", opacity: 1 },
      { transform: "translateX(0)", opacity: 1 }
    ], { duration: 300, easing: "cubic-bezier(0.16, 1, 0.3, 1)" })

    this.dismissTimer = setTimeout(() => {
      this.fadeOut()
    }, this.durationValue)
  }

  disconnect() {
    if (this.dismissTimer) {
      clearTimeout(this.dismissTimer)
    }
  }

  dismiss() {
    if (this.dismissTimer) {
      clearTimeout(this.dismissTimer)
    }
    this.fadeOut()
  }

  fadeOut() {
    const animation = this.element.animate(
      [
        { opacity: 1, transform: "translateX(0)" },
        { opacity: 0, transform: "translateX(10px)" }
      ],
      { duration: 300, easing: "ease-in", fill: "forwards" }
    )
    animation.onfinish = () => this.element.remove()
  }
}
