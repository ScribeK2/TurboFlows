import { Controller } from "@hotwired/stimulus"
import Fuse from "fuse.js"

// Global search dialog with Fuse.js fuzzy matching.
// Opens via click on search pill or Cmd+K/Ctrl+K hotkey.
export default class extends Controller {
  static targets = ["dialog", "input", "results"]
  static values = { url: String }

  connect() {
    this.workflows = null
    this.fuse = null
    this.selectedIndex = -1
    this.debounceTimer = null

    // Global hotkey: Cmd+K / Ctrl+K
    this.handleHotkey = this.handleHotkey.bind(this)
    document.addEventListener("keydown", this.handleHotkey)

    // Clear cache on page navigation
    this.clearCache = () => { this.workflows = null; this.fuse = null }
    document.addEventListener("turbo:before-visit", this.clearCache)
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleHotkey)
    document.removeEventListener("turbo:before-visit", this.clearCache)
    if (this.debounceTimer) clearTimeout(this.debounceTimer)
  }

  handleHotkey(event) {
    const tag = event.target.tagName
    if (tag === "INPUT" || tag === "TEXTAREA" || event.target.isContentEditable) return

    if ((event.metaKey || event.ctrlKey) && event.key === "k") {
      event.preventDefault()
      this.open()
    }
  }

  open() {
    this.element.dispatchEvent(new CustomEvent("dialog:show", { bubbles: true }))
    this.dialogTarget.showModal()
    this.inputTarget.value = ""
    this.inputTarget.focus()
    this.selectedIndex = -1
    this.clearResults()

    if (!this.workflows) {
      this.fetchData()
    } else {
      this.showHint()
    }
  }

  close() {
    if (this.dialogTarget.open) {
      this.dialogTarget.close()
    }
  }

  backdropClose(event) {
    if (event.target === this.dialogTarget) {
      this.close()
    }
  }

  async fetchData() {
    this.setResultsMessage("nav__search-loading", "Loading...")
    try {
      const response = await fetch(this.urlValue, {
        headers: { "Accept": "application/json" }
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      this.workflows = await response.json()
      this.fuse = new Fuse(this.workflows, {
        keys: ["title", "description", "tags"],
        includeMatches: true,
        threshold: 0.3,
        minMatchCharLength: 2
      })
      this.showHint()
    } catch (_error) {
      this.setResultsMessage("nav__search-empty", "Failed to load search data")
    }
  }

  search() {
    if (this.debounceTimer) clearTimeout(this.debounceTimer)
    this.debounceTimer = setTimeout(() => this.performSearch(), 100)
  }

  performSearch() {
    const query = this.inputTarget.value.trim()
    if (query.length < 2 || !this.fuse) {
      this.showHint()
      return
    }

    const results = this.fuse.search(query)
    this.selectedIndex = -1

    if (results.length === 0) {
      this.clearResults()
      const el = document.createElement("div")
      el.className = "nav__search-empty"
      const text = document.createTextNode("No workflows found for \u201C")
      const strong = document.createElement("strong")
      strong.textContent = query
      const endText = document.createTextNode("\u201D")
      el.append(text, strong, endText)
      this.resultsTarget.appendChild(el)
      return
    }

    this.clearResults()
    const countEl = document.createElement("div")
    countEl.className = "nav__search-count"
    countEl.textContent = `${results.length} result${results.length === 1 ? "" : "s"}`
    this.resultsTarget.appendChild(countEl)

    results.forEach((r, i) => {
      this.resultsTarget.appendChild(this.buildResult(r, i))
    })
  }

  buildResult(result, index) {
    const { item, matches } = result

    const link = document.createElement("a")
    link.href = item.path
    link.className = "nav__search-result"
    link.dataset.index = index
    link.setAttribute("role", "option")

    const content = document.createElement("div")
    content.className = "nav__search-result-content"

    const titleSpan = document.createElement("span")
    titleSpan.className = "nav__search-result-title"
    this.applyHighlights(titleSpan, item.title, matches, "title")

    const descSpan = document.createElement("span")
    descSpan.className = "nav__search-result-description"
    descSpan.textContent = item.description || ""

    content.append(titleSpan, descSpan)

    const badge = document.createElement("span")
    const isPublished = item.status === "published"
    badge.className = `nav__search-badge ${isPublished ? "nav__search-badge--published" : "nav__search-badge--draft"}`
    badge.textContent = isPublished ? "Published" : "Draft"

    link.append(content, badge)
    return link
  }

  applyHighlights(container, text, matches, key) {
    const match = matches?.find(m => m.key === key)
    if (!match) {
      container.textContent = text
      return
    }

    const indices = match.indices
      .filter(([start, end]) => end - start >= 1)
      .sort((a, b) => a[0] - b[0])

    let lastIndex = 0
    for (const [start, end] of indices) {
      if (start > lastIndex) {
        container.appendChild(document.createTextNode(text.slice(lastIndex, start)))
      }
      const mark = document.createElement("mark")
      mark.textContent = text.slice(start, end + 1)
      container.appendChild(mark)
      lastIndex = end + 1
    }
    if (lastIndex < text.length) {
      container.appendChild(document.createTextNode(text.slice(lastIndex)))
    }
  }

  navigate(event) {
    const results = this.resultsTarget.querySelectorAll(".nav__search-result")
    if (results.length === 0) return

    switch (event.key) {
      case "ArrowDown":
        event.preventDefault()
        this.selectedIndex = Math.min(this.selectedIndex + 1, results.length - 1)
        this.updateSelection(results)
        break
      case "ArrowUp":
        event.preventDefault()
        this.selectedIndex = Math.max(this.selectedIndex - 1, 0)
        this.updateSelection(results)
        break
      case "Enter":
        event.preventDefault()
        if (this.selectedIndex >= 0 && results[this.selectedIndex]) {
          results[this.selectedIndex].click()
        }
        break
    }
  }

  updateSelection(results) {
    results.forEach((el, i) => {
      el.setAttribute("aria-selected", i === this.selectedIndex ? "true" : "false")
    })
    if (this.selectedIndex >= 0) {
      results[this.selectedIndex].scrollIntoView({ block: "nearest" })
    }
  }

  showHint() {
    this.setResultsMessage("nav__search-hint", "Type to search by workflow title or description")
  }

  clearResults() {
    while (this.resultsTarget.firstChild) {
      this.resultsTarget.removeChild(this.resultsTarget.firstChild)
    }
  }

  setResultsMessage(className, text) {
    this.clearResults()
    const el = document.createElement("div")
    el.className = className
    el.textContent = text
    this.resultsTarget.appendChild(el)
  }
}
