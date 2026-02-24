import { Controller } from "@hotwired/stimulus"

// Provides markdown formatting toolbar actions for a <textarea>.
// Attach to a wrapper containing toolbar buttons and a textarea target.
//
// Usage:
//   <div data-controller="markdown-toolbar">
//     <button data-action="click->markdown-toolbar#bold">B</button>
//     <textarea data-markdown-toolbar-target="input"></textarea>
//   </div>
export default class extends Controller {
  static targets = ["input"]

  bold()          { this.#wrap("**", "**") }
  italic()        { this.#wrap("_", "_") }
  strikethrough() { this.#wrap("~~", "~~") }
  code()          { this.#wrap("`", "`") }
  heading()       { this.#prefixLine("## ") }
  quote()         { this.#prefixLine("> ") }
  bulletList()    { this.#prefixLine("- ") }
  numberedList()  { this.#prefixLine("1. ") }

  link() {
    const textarea = this.inputTarget
    const { selectionStart, selectionEnd } = textarea
    const selected = textarea.value.substring(selectionStart, selectionEnd)
    const url = selected.match(/^https?:\/\//) ? selected : "url"
    const text = url === selected ? "link text" : (selected || "link text")

    const before = textarea.value.substring(0, selectionStart)
    const after = textarea.value.substring(selectionEnd)
    const insertion = `[${text}](${url})`

    textarea.value = before + insertion + after

    // Select the url part so user can type the URL
    const urlStart = selectionStart + text.length + 3 // [text](
    textarea.selectionStart = urlStart
    textarea.selectionEnd = urlStart + url.length

    this.#afterInsert(textarea)
  }

  // -- private helpers -------------------------------------------------------

  // Wrap the current selection with before/after strings.
  // If nothing is selected, insert placeholder text.
  #wrap(before, after) {
    const textarea = this.inputTarget
    const { selectionStart, selectionEnd } = textarea
    const selected = textarea.value.substring(selectionStart, selectionEnd)
    const placeholder = selected || "text"

    const prefix = textarea.value.substring(0, selectionStart)
    const suffix = textarea.value.substring(selectionEnd)

    textarea.value = prefix + before + placeholder + after + suffix

    // Re-select the inserted text (excluding markers)
    textarea.selectionStart = selectionStart + before.length
    textarea.selectionEnd = selectionStart + before.length + placeholder.length

    this.#afterInsert(textarea)
  }

  // Prefix the current line(s) with a string (e.g. "## ", "- ", "> ").
  #prefixLine(prefix) {
    const textarea = this.inputTarget
    const { selectionStart, selectionEnd } = textarea
    const value = textarea.value

    // Find the start of the current line
    const lineStart = value.lastIndexOf("\n", selectionStart - 1) + 1
    // Find the end of the last selected line
    let lineEnd = value.indexOf("\n", selectionEnd)
    if (lineEnd === -1) lineEnd = value.length

    const selectedLines = value.substring(lineStart, lineEnd)
    const prefixed = selectedLines
      .split("\n")
      .map(line => prefix + line)
      .join("\n")

    textarea.value = value.substring(0, lineStart) + prefixed + value.substring(lineEnd)

    // Place cursor at end of prefixed content
    const newEnd = lineStart + prefixed.length
    textarea.selectionStart = newEnd
    textarea.selectionEnd = newEnd

    this.#afterInsert(textarea)
  }

  // Fire an input event so other controllers (autosave, collaboration) react.
  #afterInsert(textarea) {
    textarea.focus()
    textarea.dispatchEvent(new Event("input", { bubbles: true }))
  }
}
