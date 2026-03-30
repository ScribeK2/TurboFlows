import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["urlField", "embedCode"]
  static values = { generateUrl: String, revokeUrl: String }

  async generate() {
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    const response = await fetch(this.generateUrlValue, {
      method: "POST",
      headers: { "X-CSRF-Token": token }
    })

    if (response.ok || response.redirected) {
      window.location.reload()
    }
  }

  async revoke() {
    if (!confirm("Revoke the share link? Existing links will stop working.")) return

    const token = document.querySelector('meta[name="csrf-token"]')?.content
    const response = await fetch(this.revokeUrlValue, {
      method: "DELETE",
      headers: { "X-CSRF-Token": token }
    })

    if (response.ok || response.redirected) {
      window.location.reload()
    }
  }

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
