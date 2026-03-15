import { Controller } from "@hotwired/stimulus"

/**
 * Instruction Template Controller
 * 
 * Sprint 2: Action Step Simplification
 * Provides pre-written instruction snippets for common CSR tasks.
 * Templates can be inserted into the instructions textarea with one click.
 */
export default class extends Controller {
  static targets = [
    "instructionsField",
    "templatePanel",
    "categoryTabs",
    "templateList",
    "searchInput",
    "previewPanel"
  ]

  static values = {
    insertMode: { type: String, default: "append" } // "append" | "replace"
  }

  // SVG icon paths for template items (stroke-based, matching Kizuflow style)
  iconPaths = {
    // Greeting
    "chat": "M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z",
    "phone": "M3 5a2 2 0 012-2h3.28a1 1 0 01.948.684l1.498 4.493a1 1 0 01-.502 1.21l-2.257 1.13a11.042 11.042 0 005.516 5.516l1.13-2.257a1 1 0 011.21-.502l4.493 1.498a1 1 0 01.684.949V19a2 2 0 01-2 2h-1C9.716 21 3 14.284 3 6V5z",
    "arrow-up": "M5 10l7-7m0 0l7 7m-7-7v18",
    // Verification
    "shield": "M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z",
    "globe": "M21 12a9 9 0 01-9 9m9-9a9 9 0 00-9-9m9 9H3m9 9a9 9 0 01-9-9m9 9c1.657 0 3-4.03 3-9s-1.343-9-3-9m0 18c-1.657 0-3-4.03-3-9s1.343-9 3-9m-9 9a9 9 0 019-9",
    "device": "M12 18h.01M8 21h8a2 2 0 002-2V5a2 2 0 00-2-2H8a2 2 0 00-2 2v14a2 2 0 002 2z",
    // Troubleshooting
    "trash": "M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16",
    "window": "M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z",
    "eye-off": "M13.875 18.825A10.05 10.05 0 0112 19c-4.478 0-8.268-2.943-9.543-7a9.97 9.97 0 011.563-3.029m5.858.908a3 3 0 114.243 4.243M9.878 9.878l4.242 4.242M9.88 9.88l-3.29-3.29m7.532 7.532l3.29 3.29M3 3l3.59 3.59m0 0A9.953 9.953 0 0112 5c4.478 0 8.268 2.943 9.543 7a10.025 10.025 0 01-4.132 5.411m0 0L21 21",
    "refresh": "M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15",
    // Email
    "mail": "M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z",
    "check-circle": "M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z",
    "mail-open": "M3 19V9a2 2 0 012-2h.93a2 2 0 001.664-.89l.812-1.22A2 2 0 0110.07 4h3.86a2 2 0 011.664.89l.812 1.22A2 2 0 0018.07 7H19a2 2 0 012 2v10a2 2 0 01-2 2H5a2 2 0 01-2-2z",
    // DNS
    "clock": "M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z",
    "search": "M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z",
    // Closing
    "calendar": "M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"
  }

  // Pre-defined instruction templates organized by category
  templates = {
    greeting: [
      {
        id: "greet-standard",
        name: "Standard Greeting",
        icon: "chat",
        content: "Thank the customer for calling and introduce yourself by name. Verify you're speaking with the account holder."
      },
      {
        id: "greet-callback",
        name: "Callback Greeting",
        icon: "phone",
        content: "Thank the customer for returning the call. Reference the previous ticket/issue and confirm they're ready to continue troubleshooting."
      },
      {
        id: "greet-escalation",
        name: "Escalation Introduction",
        icon: "arrow-up",
        content: "Introduce yourself as a senior support representative. Acknowledge the customer's previous experience and assure them you'll work to resolve the issue."
      }
    ],
    verification: [
      {
        id: "verify-account",
        name: "Account Verification",
        icon: "shield",
        content: "Ask the customer to verify their account by providing:\n- Full name on the account\n- Email address associated with the account\n- Last 4 digits of payment method (if applicable)"
      },
      {
        id: "verify-domain",
        name: "Domain Ownership",
        icon: "globe",
        content: "Verify domain ownership by asking the customer to confirm:\n- Domain name\n- Registrant email address\n- Date of registration (approximate)"
      },
      {
        id: "verify-2fa",
        name: "Two-Factor Auth",
        icon: "device",
        content: "Inform the customer a verification code has been sent to their registered phone/email. Ask them to provide the code to proceed."
      }
    ],
    troubleshooting: [
      {
        id: "ts-clear-cache",
        name: "Clear Browser Cache",
        icon: "trash",
        content: "Ask the customer to clear their browser cache and cookies:\n1. Press Ctrl+Shift+Delete (Windows) or Cmd+Shift+Delete (Mac)\n2. Select 'All time' for the time range\n3. Check 'Cached images and files' and 'Cookies'\n4. Click 'Clear data'\n5. Restart the browser and try again"
      },
      {
        id: "ts-different-browser",
        name: "Try Different Browser",
        icon: "window",
        content: "Ask the customer to try accessing the service using a different browser (Chrome, Firefox, Safari, or Edge) to rule out browser-specific issues."
      },
      {
        id: "ts-incognito",
        name: "Try Incognito Mode",
        icon: "eye-off",
        content: "Ask the customer to open an incognito/private browsing window:\n- Chrome: Ctrl+Shift+N (Windows) or Cmd+Shift+N (Mac)\n- Firefox: Ctrl+Shift+P (Windows) or Cmd+Shift+P (Mac)\n- Then navigate to the page and try again"
      },
      {
        id: "ts-restart-device",
        name: "Restart Device",
        icon: "refresh",
        content: "Ask the customer to restart their device (computer/phone) and try the operation again after it fully reboots."
      }
    ],
    email: [
      {
        id: "email-check-spam",
        name: "Check Spam Folder",
        icon: "mail",
        content: "Ask the customer to check their spam/junk folder for the expected email. If found, mark it as 'Not Spam' to ensure future emails arrive in the inbox."
      },
      {
        id: "email-whitelist",
        name: "Whitelist Our Domain",
        icon: "check-circle",
        content: "Ask the customer to add our email domain to their contacts or safe senders list to prevent future emails from being filtered."
      },
      {
        id: "email-resend",
        name: "Resend Verification Email",
        icon: "mail-open",
        content: "Inform the customer you're resending the verification email. Ask them to wait 5-10 minutes and check both inbox and spam folders."
      }
    ],
    dns: [
      {
        id: "dns-propagation",
        name: "DNS Propagation Wait",
        icon: "clock",
        content: "Explain to the customer that DNS changes can take up to 24-48 hours to propagate globally. Recommend checking back in 24 hours if changes are not yet visible."
      },
      {
        id: "dns-flush-cache",
        name: "Flush DNS Cache",
        icon: "refresh",
        content: "Guide the customer to flush their local DNS cache:\n\nWindows:\n1. Open Command Prompt as Administrator\n2. Type: ipconfig /flushdns\n3. Press Enter\n\nMac:\n1. Open Terminal\n2. Type: sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder\n3. Press Enter and provide password if prompted"
      },
      {
        id: "dns-check-records",
        name: "Verify DNS Records",
        icon: "search",
        content: "Use a DNS lookup tool to verify the customer's DNS records are correctly configured. Check A records, CNAME records, MX records, and TXT records as applicable."
      }
    ],
    closing: [
      {
        id: "close-resolved",
        name: "Issue Resolved",
        icon: "check-circle",
        content: "Confirm with the customer that the issue has been resolved. Ask if there's anything else you can help with today. Thank them for their patience and for choosing our service."
      },
      {
        id: "close-followup",
        name: "Follow-up Required",
        icon: "calendar",
        content: "Explain that the issue requires further investigation. Provide a ticket number and expected follow-up timeframe. Assure the customer they'll receive an update via email."
      },
      {
        id: "close-escalation",
        name: "Escalation Handoff",
        icon: "arrow-up",
        content: "Explain that you're escalating the issue to a specialist team. Provide the escalation ticket number and expected response time. Thank the customer for their patience."
      }
    ]
  }

  connect() {
    this.currentCategory = "greeting"
    this.filteredTemplates = []
    
    // Render initial templates
    this.renderTemplates()
  }

  /**
   * Toggle the template panel visibility
   */
  togglePanel() {
    if (this.hasTemplatePanelTarget) {
      this.templatePanelTarget.classList.toggle("hidden")
      
      // Focus search input when opening
      if (!this.templatePanelTarget.classList.contains("hidden") && this.hasSearchInputTarget) {
        setTimeout(() => this.searchInputTarget.focus(), 100)
      }
    }
  }

  /**
   * Close the template panel
   */
  closePanel() {
    if (this.hasTemplatePanelTarget) {
      this.templatePanelTarget.classList.add("hidden")
    }
  }

  /**
   * Switch category tab
   */
  selectCategory(event) {
    const category = event.currentTarget.dataset.category
    this.currentCategory = category
    
    // Update tab styles
    if (this.hasCategoryTabsTarget) {
      this.categoryTabsTarget.querySelectorAll("button").forEach(btn => {
        const isActive = btn.dataset.category === category
        btn.classList.toggle("is-active", isActive)
        btn.classList.toggle("is-inactive", !isActive)
      })
    }
    
    // Clear search and render templates
    if (this.hasSearchInputTarget) {
      this.searchInputTarget.value = ""
    }
    this.renderTemplates()
  }

  /**
   * Search templates
   */
  searchTemplates() {
    const query = this.hasSearchInputTarget ? this.searchInputTarget.value.toLowerCase().trim() : ""
    this.renderTemplates(query)
  }

  /**
   * Render templates for current category (optionally filtered)
   */
  renderTemplates(searchQuery = "") {
    if (!this.hasTemplateListTarget) return
    
    let templates = this.templates[this.currentCategory] || []
    
    // Filter by search query if provided
    if (searchQuery) {
      // Search across all categories
      templates = Object.values(this.templates).flat().filter(t =>
        t.name.toLowerCase().includes(searchQuery) ||
        t.content.toLowerCase().includes(searchQuery)
      )
    }
    
    // Render template items
    this.templateListTarget.innerHTML = templates.map(template => `
      <button type="button"
              class="w-full text-left p-3 rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800 hover:bg-slate-50 dark:hover:bg-slate-700 hover:border-emerald-300 dark:hover:border-emerald-600 transition-all duration-200 group"
              data-action="click->instruction-template#insertTemplate"
              data-template-id="${template.id}"
              data-template-content="${this.escapeHtml(template.content)}">
        <div class="flex items-start gap-3">
          <svg class="w-5 h-5 text-slate-400 dark:text-slate-500 group-hover:text-emerald-500 dark:group-hover:text-emerald-400 flex-shrink-0 mt-0.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="${this.iconPaths[template.icon] || this.iconPaths['chat']}"/>
          </svg>
          <div class="flex-1 min-w-0">
            <div class="font-medium text-slate-900 dark:text-slate-100 text-sm group-hover:text-emerald-600 dark:group-hover:text-emerald-400">
              ${template.name}
            </div>
            <div class="text-xs text-slate-500 dark:text-slate-400 mt-1 line-clamp-2">
              ${this.escapeHtml(template.content.substring(0, 80))}${template.content.length > 80 ? '...' : ''}
            </div>
          </div>
          <svg class="w-4 h-4 text-slate-400 group-hover:text-emerald-500 flex-shrink-0 mt-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"/>
          </svg>
        </div>
      </button>
    `).join("")

    // Show empty state if no templates
    if (templates.length === 0) {
      this.templateListTarget.innerHTML = `
        <div class="text-center py-8 text-slate-500 dark:text-slate-400">
          <svg class="mx-auto h-10 w-10 mb-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M9.172 16.172a4 4 0 015.656 0M9 10h.01M15 10h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
          </svg>
          <p class="text-sm">No templates found</p>
        </div>
      `
    }
  }

  /**
   * Insert a template into the instructions field
   */
  insertTemplate(event) {
    const content = event.currentTarget.dataset.templateContent
    if (!content || !this.hasInstructionsFieldTarget) return
    
    const textarea = this.instructionsFieldTarget
    const currentValue = textarea.value
    
    if (this.insertModeValue === "replace" || currentValue.trim() === "") {
      // Replace mode or empty field
      textarea.value = content
    } else {
      // Append mode - add to existing content
      textarea.value = currentValue + (currentValue.endsWith("\n") ? "" : "\n\n") + content
    }
    
    // Trigger input event for autosave and preview
    textarea.dispatchEvent(new Event("input", { bubbles: true }))
    
    // Close panel
    this.closePanel()
    
    // Focus textarea
    textarea.focus()
    
    // Scroll textarea to show new content
    textarea.scrollTop = textarea.scrollHeight
  }

  /**
   * Preview a template (on hover)
   */
  previewTemplate(event) {
    if (!this.hasPreviewPanelTarget) return
    
    const content = event.currentTarget.dataset.templateContent
    if (!content) return
    
    this.previewPanelTarget.textContent = content
    this.previewPanelTarget.classList.remove("hidden")
  }

  /**
   * Hide preview panel
   */
  hidePreview() {
    if (this.hasPreviewPanelTarget) {
      this.previewPanelTarget.classList.add("hidden")
    }
  }

  /**
   * Toggle insert mode between append and replace
   */
  toggleInsertMode(event) {
    this.insertModeValue = event.currentTarget.checked ? "replace" : "append"
  }

  /**
   * Get all templates as flat array (for external use)
   */
  getAllTemplates() {
    return Object.entries(this.templates).flatMap(([category, templates]) =>
      templates.map(t => ({ ...t, category }))
    )
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

