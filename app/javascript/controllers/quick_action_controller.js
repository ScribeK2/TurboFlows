import { Controller } from "@hotwired/stimulus"

/**
 * Quick Action Controller
 * 
 * Sprint 2: Action Step Simplification
 * Provides one-click action buttons for common CSR tasks.
 * Buttons insert pre-formatted text with placeholders into the instructions field.
 */
export default class extends Controller {
  static targets = [
    "instructionsField",
    "actionTypeField",
    "buttonsContainer"
  ]

  // Quick action definitions with prefixes and optional action types
  quickActions = [
    {
      id: "tell-customer",
      label: "Tell customer...",
      prefix: "Tell the customer: ",
      placeholder: "[what to tell them]"
    },
    {
      id: "ask-customer",
      label: "Ask customer...",
      prefix: "Ask the customer: ",
      placeholder: "[question to ask]"
    },
    {
      id: "verify-that",
      label: "Verify that...",
      prefix: "Verify that: ",
      placeholder: "[what to verify]"
    },
    {
      id: "navigate-to",
      label: "Navigate to...",
      prefix: "Navigate to: ",
      placeholder: "[location/page/section]"
    },
    {
      id: "click-on",
      label: "Click on...",
      prefix: "Click on: ",
      placeholder: "[button/link/element]"
    },
    {
      id: "wait-for",
      label: "Wait for...",
      prefix: "Wait for: ",
      placeholder: "[condition/time period]"
    },
    {
      id: "confirm-with",
      label: "Confirm with...",
      prefix: "Confirm with the customer that: ",
      placeholder: "[what to confirm]"
    },
    {
      id: "document-in",
      label: "Document in...",
      prefix: "Document the following in the ticket: ",
      placeholder: "[what to document]"
    }
  ]

  connect() {
    // Render quick action buttons if container exists
    if (this.hasButtonsContainerTarget) {
      this.renderButtons()
    }
  }

  /**
   * Render quick action buttons
   */
  // Trust boundary: quickActions is a hardcoded constant in this controller.
  // action.label, action.prefix, and action.placeholder are all escaped via escapeHtml.
  renderButtons() {
    if (!this.hasButtonsContainerTarget) return

    this.buttonsContainerTarget.innerHTML = this.quickActions.map(action => `
      <button type="button"
              class="quick-action-btn"
              style="background-color: #f8fafc; color: #475569; border-color: #e2e8f0;"
              onmouseover="this.style.backgroundColor='#f1f5f9'"
              onmouseout="this.style.backgroundColor='#f8fafc'"
              data-action="click->quick-action#insertAction"
              data-prefix="${this.escapeHtml(action.prefix)}"
              data-placeholder="${this.escapeHtml(action.placeholder)}">
        ${this.escapeHtml(action.label)}
      </button>
    `).join("")
  }

  /**
   * Insert a quick action prefix into the instructions field
   */
  insertAction(event) {
    const prefix = event.currentTarget.dataset.prefix
    const placeholder = event.currentTarget.dataset.placeholder
    
    if (!prefix || !this.hasInstructionsFieldTarget) return
    
    const textarea = this.instructionsFieldTarget
    const currentValue = textarea.value
    const cursorPosition = textarea.selectionStart
    const textToInsert = prefix + placeholder
    
    // If there's existing content, add a newline before
    let newValue
    let newCursorPosition
    
    if (currentValue.trim() === "") {
      // Empty field - just insert
      newValue = textToInsert
      newCursorPosition = prefix.length
    } else if (cursorPosition === currentValue.length) {
      // Cursor at end - append with newline
      const needsNewline = !currentValue.endsWith("\n")
      newValue = currentValue + (needsNewline ? "\n" : "") + textToInsert
      newCursorPosition = newValue.length - placeholder.length
    } else {
      // Cursor in middle - insert at cursor position
      const before = currentValue.substring(0, cursorPosition)
      const after = currentValue.substring(cursorPosition)
      const needsNewlineBefore = before.length > 0 && !before.endsWith("\n")
      const needsNewlineAfter = after.length > 0 && !after.startsWith("\n")
      
      newValue = before + 
                 (needsNewlineBefore ? "\n" : "") + 
                 textToInsert + 
                 (needsNewlineAfter ? "\n" : "") + 
                 after
      newCursorPosition = before.length + (needsNewlineBefore ? 1 : 0) + prefix.length
    }
    
    // Update textarea
    textarea.value = newValue
    
    // Trigger input event for autosave and preview
    textarea.dispatchEvent(new Event("input", { bubbles: true }))
    
    // Focus and select the placeholder text
    textarea.focus()
    textarea.setSelectionRange(newCursorPosition, newCursorPosition + placeholder.length)
  }

  /**
   * Insert a custom quick action (for external use)
   */
  insertCustomAction(prefix, placeholder = "") {
    if (!this.hasInstructionsFieldTarget) return
    
    const textarea = this.instructionsFieldTarget
    const currentValue = textarea.value
    const textToInsert = prefix + placeholder
    
    if (currentValue.trim() === "") {
      textarea.value = textToInsert
    } else {
      textarea.value = currentValue + (currentValue.endsWith("\n") ? "" : "\n") + textToInsert
    }
    
    textarea.dispatchEvent(new Event("input", { bubbles: true }))
    textarea.focus()
    
    if (placeholder) {
      const start = textarea.value.length - placeholder.length
      textarea.setSelectionRange(start, textarea.value.length)
    }
  }

  /**
   * Escape HTML to prevent XSS
   */
  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}

