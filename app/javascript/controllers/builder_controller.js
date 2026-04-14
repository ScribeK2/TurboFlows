import { Controller } from "@hotwired/stimulus"

// Manages the builder shell: panel open/close, mode toggle, keyboard shortcuts.
export default class extends Controller {
  static targets = ["panel", "titleInput"]
  static values = {
    mode: { type: String, default: "view" },
    workflowId: Number
  }

  connect() {
    this.boundKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.boundKeydown)

    const params = new URLSearchParams(window.location.search)
    if (params.get("health") === "true") {
      requestAnimationFrame(() => this.openHealth())
    }
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundKeydown)
  }

  openStep(event) {
    const url = event.currentTarget.dataset.builderUrlParam
    if (!url) return

    event.preventDefault()
    event.stopPropagation()

    this.element.querySelectorAll(".builder__list-row--selected").forEach(el => {
      el.classList.remove("builder__list-row--selected")
    })
    event.currentTarget.classList.add("builder__list-row--selected")

    this.loadPanel(url)
  }

  openFlowDiagram() {
    const url = this.element.querySelector("[data-builder-flow-url-value]")
      ?.dataset.builderFlowUrlValue
    if (url) {
      this.clearSelectedRow()
      this.loadPanel(url)
    }
  }

  openSettings() {
    const url = this.element.querySelector("[data-builder-settings-url-value]")
      ?.dataset.builderSettingsUrlValue
    if (url) {
      this.clearSelectedRow()
      this.loadPanel(url)
    }
  }

  openHealth() {
    const url = this.element.dataset.builderHealthUrlValue
    if (url) {
      this.clearSelectedRow()
      this.loadPanel(url)
    }
  }

  closePanel() {
    this.element.classList.remove("builder--panel-open")
    this.clearSelectedRow()

    if (this.hasPanelTarget) {
      this.panelTarget.removeAttribute("src")
      while (this.panelTarget.firstChild) {
        this.panelTarget.removeChild(this.panelTarget.firstChild)
      }
    }
  }

  panelLoaded() {
    this.element.classList.add("builder--panel-open")
  }

  saveTitle(event) {
    if (this.modeValue !== "edit") return

    const input = event.currentTarget
    const url = input.dataset.url
    const title = input.value.trim()

    if (!title || !url) return

    const token = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(url, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": token,
        "Accept": "application/json"
      },
      body: JSON.stringify({ workflow: { title } })
    }).then(response => {
      const statusEl = document.getElementById("autosave-status")
      if (statusEl) {
        statusEl.textContent = response.ok ? "Saved" : "Save failed"
        statusEl.className = response.ok
          ? "builder__autosave builder__autosave--saved"
          : "builder__autosave builder__autosave--error"
      }
    })
  }

  loadPanel(url) {
    if (this.hasPanelTarget) {
      this.panelTarget.src = url
    }
  }

  clearSelectedRow() {
    this.element.querySelectorAll(".builder__list-row--selected").forEach(el => {
      el.classList.remove("builder__list-row--selected")
    })
  }

  handleKeydown(event) {
    if (event.key === "Escape" && this.element.classList.contains("builder--panel-open")) {
      this.closePanel()
    }
  }
}
