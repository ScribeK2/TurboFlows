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

    this.element.querySelectorAll(".builder__step--selected").forEach(el => {
      el.classList.remove("builder__step--selected")
    })
    event.currentTarget.classList.add("builder__step--selected")

    this.loadPanel(url)
  }

  // The empty state points at the toolbar's Templates popover rather than
  // duplicating the template grid, so this just opens the one that exists.
  focusTemplates() {
    const trigger = this.element.querySelector("[data-action*='template-picker#toggle']")
    if (!trigger) return

    trigger.scrollIntoView({ block: "nearest" })

    // Defer past this click: template-picker closes on any document click
    // landing outside itself, and this button is outside it.
    requestAnimationFrame(() => trigger.click())
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
    this.clearSelectedRow()

    if (this.hasPanelTarget) {
      this.panelTarget.removeAttribute("src")
      while (this.panelTarget.firstChild) {
        this.panelTarget.removeChild(this.panelTarget.firstChild)
      }
    }
  }

  // Whether the panel is open, read from the same fact the CSS uses: does the
  // frame have content. Nothing has to remember to set a flag, so no injection
  // path can leave the two disagreeing.
  get panelOpen() {
    return this.hasPanelTarget && this.panelTarget.children.length > 0
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
    }).then(async response => {
      const statusEl = document.getElementById("autosave-status")
      if (!statusEl) return

      if (response.ok) {
        statusEl.textContent = "Saved"
        statusEl.className = "builder__autosave builder__autosave--saved"
        return
      }

      // The JSON error body carries the reason. Details shows it through its
      // Turbo Stream partial; a bare "Save failed" here left the author guessing.
      const body = await response.json().catch(() => ({}))
      const reason = Array.isArray(body.errors) ? body.errors[0] : null
      statusEl.textContent = reason ? `Save failed — ${reason}` : "Save failed"
      statusEl.className = "builder__autosave builder__autosave--error"
    })
  }

  // In view mode every panel is a preview, whatever the person may do: the
  // server decides readonly from this flag or from permission, so a row
  // rendered by a broadcast (which knows no mode) still opens as a preview.
  loadPanel(url) {
    if (!this.hasPanelTarget) return

    this.panelTarget.src = this.modeValue === "edit" ? url : this.readonlyUrl(url)
  }

  readonlyUrl(url) {
    const resolved = new URL(url, window.location.origin)
    resolved.searchParams.set("readonly", "1")
    return resolved.pathname + resolved.search
  }

  clearSelectedRow() {
    this.element.querySelectorAll(".builder__step--selected").forEach(el => {
      el.classList.remove("builder__step--selected")
    })
  }

  handleKeydown(event) {
    if (event.key === "Escape" && this.panelOpen) {
      this.closePanel()
    }
  }
}
