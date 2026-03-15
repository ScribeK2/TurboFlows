import { Controller } from "@hotwired/stimulus"

// Opens a template preview modal and triggers the flow preview render
export default class extends Controller {
  static values = { templateId: Number }

  open() {
    const modal = document.getElementById(`template-preview-modal-${this.templateIdValue}`)
    if (!modal) return

    modal.classList.remove("is-hidden")
    document.body.style.overflow = "hidden"

    // Trigger flow preview render after modal is visible
    setTimeout(() => {
      const previewContainer = document.getElementById(`modal-preview-${this.templateIdValue}`)
      if (!previewContainer) return

      const controllerEl = previewContainer.closest('[data-controller*="template-flow-preview"]')
      if (!controllerEl) return

      const application = window.Stimulus
      if (application) {
        try {
          const previewController = application.getControllerForElementAndIdentifier(controllerEl, "template-flow-preview")
          if (previewController && typeof previewController.render === "function") {
            previewController.render()
          }
        } catch (e) {
          controllerEl.dispatchEvent(new CustomEvent("render-preview"))
        }
      }
    }, 100)
  }
}
