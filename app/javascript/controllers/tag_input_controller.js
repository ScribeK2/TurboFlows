import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "suggestions", "pills"]
  static values = { url: String }

  connect() {
    this.allTags = []
    this.fetchTags()
  }

  async fetchTags() {
    const response = await fetch(this.urlValue)
    this.allTags = await response.json()
  }

  onInput() {
    const query = this.inputTarget.value.trim().toLowerCase()
    if (query.length < 1) {
      this.suggestionsTarget.hidden = true
      return
    }

    const currentIds = this.currentTagIds()
    const matches = this.allTags
      .filter(t => t.name.toLowerCase().includes(query) && !currentIds.includes(t.id))
      .slice(0, 8)

    // Clear suggestions using textContent (safe, no innerHTML)
    this.suggestionsTarget.textContent = ""

    if (matches.length === 0 && query.length > 0) {
      const createEl = document.createElement("div")
      createEl.className = "tag-suggestion tag-suggestion--create"
      createEl.dataset.action = "click->tag-input#createTag"
      createEl.dataset.name = this.inputTarget.value.trim()
      createEl.textContent = `Create "${this.inputTarget.value.trim()}"`
      this.suggestionsTarget.appendChild(createEl)
      this.suggestionsTarget.hidden = false
    } else if (matches.length > 0) {
      matches.forEach(t => {
        const el = document.createElement("div")
        el.className = "tag-suggestion"
        el.dataset.action = "click->tag-input#selectTag"
        el.dataset.tagId = t.id
        el.dataset.tagName = t.name
        el.textContent = t.name
        this.suggestionsTarget.appendChild(el)
      })
      this.suggestionsTarget.hidden = false
    } else {
      this.suggestionsTarget.hidden = true
    }
  }

  onKeydown(event) {
    if (event.key === "Escape") {
      this.suggestionsTarget.hidden = true
      this.inputTarget.value = ""
    } else if (event.key === "Enter") {
      event.preventDefault()
      const firstSuggestion = this.suggestionsTarget.querySelector(".tag-suggestion")
      if (firstSuggestion) firstSuggestion.click()
    }
  }

  selectTag(event) {
    const tagId = parseInt(event.target.dataset.tagId)
    const tagName = event.target.dataset.tagName
    this.addTagToWorkflow(tagId, tagName)
  }

  async createTag() {
    const name = this.inputTarget.value.trim()
    if (!name) return

    const token = document.querySelector('meta[name="csrf-token"]')?.content
    const response = await fetch("/tags", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": token, Accept: "application/json" },
      body: JSON.stringify({ tag: { name } })
    })

    if (response.ok) {
      const tag = await response.json()
      this.allTags.push(tag)
      this.addTagToWorkflow(tag.id, tag.name)
    }
  }

  async addTagToWorkflow(tagId, tagName) {
    const workflowId = this.element.closest("[data-workflow-id]")?.dataset.workflowId
    if (!workflowId) return

    const token = document.querySelector('meta[name="csrf-token"]')?.content
    await fetch(`/workflows/${workflowId}/taggings`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": token, Accept: "text/vnd.turbo-stream.html" },
      body: JSON.stringify({ tag_id: tagId })
    })

    this.appendPill(tagId, tagName)
    this.inputTarget.value = ""
    this.suggestionsTarget.hidden = true
  }

  async removeTag(event) {
    const tagId = event.params.tagId
    const workflowId = this.element.closest("[data-workflow-id]")?.dataset.workflowId
    if (!workflowId) return

    const token = document.querySelector('meta[name="csrf-token"]')?.content
    await fetch(`/workflows/${workflowId}/taggings/${tagId}`, {
      method: "DELETE",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": token, Accept: "text/vnd.turbo-stream.html" }
    })

    event.target.closest(".tag-pill")?.remove()
  }

  appendPill(id, name) {
    const pill = document.createElement("span")
    pill.className = "tag-pill"
    pill.dataset.tagId = id
    pill.textContent = name

    const removeBtn = document.createElement("button")
    removeBtn.type = "button"
    removeBtn.className = "tag-pill__remove"
    removeBtn.dataset.action = "tag-input#removeTag"
    removeBtn.dataset.tagInputTagIdParam = id
    removeBtn.textContent = "\u00d7"
    pill.appendChild(removeBtn)

    this.pillsTarget.appendChild(pill)
  }

  currentTagIds() {
    return Array.from(this.pillsTarget.querySelectorAll("[data-tag-id]"))
      .map(el => parseInt(el.dataset.tagId))
  }
}
