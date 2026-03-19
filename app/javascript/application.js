// Entry point for the application - loaded via importmap
import "@hotwired/turbo-rails"
import "lexxy"

// Patch Lexxy CodeLanguagePicker to guard against null parent during SortableJS
// drag operations. SortableJS detaches/reattaches DOM elements, which triggers
// disconnectedCallback → #reset (destroying the editor) → connectedCallback
// on child elements that can no longer find their parent lexxy-editor.
// See: https://github.com/nicholasgasior/lexxy/issues/TBD
const CodeLanguagePickerClass = customElements.get("lexxy-code-language-picker")
if (CodeLanguagePickerClass) {
  const origConnected = CodeLanguagePickerClass.prototype.connectedCallback
  CodeLanguagePickerClass.prototype.connectedCallback = function () {
    if (!this.closest("lexxy-editor")?.editor) return
    origConnected.call(this)
  }
}

import "controllers"
