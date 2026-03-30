import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["urlField", "embedCode"]

  copy() {
    if (this.hasUrlFieldTarget) {
      navigator.clipboard.writeText(this.urlFieldTarget.value)
      this.flash(this.urlFieldTarget, "Copied!")
    }
  }

  copyEmbed() {
    if (this.hasEmbedCodeTarget) {
      navigator.clipboard.writeText(this.embedCodeTarget.value)
      this.flash(this.embedCodeTarget, "Copied!")
    }
  }

  flash(element, message) {
    const original = element.value
    element.value = message
    setTimeout(() => { element.value = original }, 1500)
  }
}
