import { Controller } from "@hotwired/stimulus"

// Toggles between List, Visual, and Split editor views on step2/edit.
// Manages visibility of #list-editor-container and #visual-editor-container,
// and syncs state between the two editors when switching modes.
//
// Modes:
//   - list: List editor only (default)
//   - visual: Visual (graph) editor only
//   - split: List editor + flow preview side-by-side
export default class extends Controller {
  static targets = ["listBtn", "visualBtn", "splitBtn", "modeInput"]
  static values = { mode: { type: String, default: "list" } }

  connect() {
    this.listContainer = document.getElementById("list-editor-container")
    this.visualContainer = document.getElementById("visual-editor-container")

    // Restore preferred mode from localStorage.
    // Only restore "list" and "split" — "visual" requires explicit activation
    // because it needs loadFromListForm() which can't run reliably on page load.
    const savedMode = localStorage.getItem("turboflows:editor-mode")
    if (savedMode === "split") {
      this.modeValue = "split"
    }

    this.applyMode()
  }

  async switchToList() {
    const visualEditor = this.getVisualEditorController()

    // If visual editor has unsaved changes, save them first via sync_steps API
    if (visualEditor && visualEditor.isDirty()) {
      const shouldSave = confirm("Save visual editor changes before switching to list view?")
      if (shouldSave) {
        await visualEditor.saveToServer()
      }
    }

    // Navigate via Turbo Drive so the list editor gets fresh server data
    // without triggering a raw browser reload (which causes a black flash
    // during cross-document view transitions).
    localStorage.setItem("turboflows:editor-mode", "list")
    Turbo.visit(window.location.href, { action: "replace" })
  }

  switchToVisual() {
    this.modeValue = "visual"
    localStorage.setItem("turboflows:editor-mode", "visual")
    this.applyMode()

    // Load current list form state into visual editor
    const visualEditor = this.getVisualEditorController()
    if (visualEditor) {
      visualEditor.loadFromListForm()
    }
  }

  switchToSplit() {
    this.modeValue = "split"
    localStorage.setItem("turboflows:editor-mode", "split")
    this.applyMode()
  }

  applyMode() {
    const mode = this.modeValue
    const isList = mode === "list"
    const isVisual = mode === "visual"
    const isSplit = mode === "split"

    // List container visible in list and split modes
    if (this.listContainer) {
      this.listContainer.classList.toggle("is-hidden", isVisual)
    }
    // Visual container visible only in visual mode
    if (this.visualContainer) {
      this.visualContainer.classList.toggle("is-hidden", !isVisual)
    }

    // Toggle split layout class on editor layout wrapper (outside controller scope)
    const editorLayout = this.listContainer?.querySelector(".wf-editor-layout")
    if (editorLayout) {
      editorLayout.classList.toggle("wf-editor-layout--split", isSplit)
    }

    // In visual mode, disable HTML validation (visual editor saves via API)
    const form = this.listContainer?.closest("form")
    if (form) {
      if (isVisual) {
        form.setAttribute("novalidate", "")
      } else {
        form.removeAttribute("novalidate")
      }
    }

    // Update button styling
    if (this.hasListBtnTarget) {
      this.listBtnTarget.classList.toggle("is-active", isList)
    }
    if (this.hasVisualBtnTarget) {
      this.visualBtnTarget.classList.toggle("is-active", isVisual)
    }
    if (this.hasSplitBtnTarget) {
      this.splitBtnTarget.classList.toggle("is-active", isSplit)
    }

    // Update hidden mode input
    if (this.hasModeInputTarget) {
      this.modeInputTarget.value = this.modeValue
    }
  }

  getVisualEditorController() {
    const el = document.getElementById("visual-editor-container")
    if (!el) return null
    return this.application.getControllerForElementAndIdentifier(el, "visual-editor")
  }
}
