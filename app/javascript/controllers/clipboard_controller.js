import { Controller } from "@hotwired/stimulus"

// Reusable copy-to-clipboard controller.
//
// Usage:
//   <div data-controller="clipboard">
//     <div data-clipboard-target="source">Text to copy</div>
//     <button data-action="click->clipboard#copy" data-clipboard-target="button">
//       <svg>...</svg> <!-- clipboard icon -->
//     </button>
//   </div>
export default class extends Controller {
  static targets = ["source", "button"]

  copy() {
    const text = this.sourceTarget.textContent.trim()

    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(() => {
        this.showSuccess()
      }).catch(() => {
        this.fallbackCopy(text)
      })
    } else {
      this.fallbackCopy(text)
    }
  }

  fallbackCopy(text) {
    const textarea = document.createElement("textarea")
    textarea.value = text
    textarea.style.position = "fixed"
    textarea.style.opacity = "0"
    document.body.appendChild(textarea)
    textarea.select()
    try {
      document.execCommand("copy")
      this.showSuccess()
    } catch {
      // Silent fail — clipboard not available
    }
    document.body.removeChild(textarea)
  }

  showSuccess() {
    if (!this.hasButtonTarget) return

    // Trust boundary: original is the developer-authored button HTML (SVG icon).
    // The replacement is a static checkmark SVG. No user data is interpolated.
    const original = this.buttonTarget.innerHTML

    // Replace with checkmark icon
    this.buttonTarget.innerHTML = `
      <svg class="w-4 h-4 text-green-500" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"></path>
      </svg>
    `

    // Restore after 2 seconds
    setTimeout(() => {
      this.buttonTarget.innerHTML = original
    }, 2000)
  }
}
