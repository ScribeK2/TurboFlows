import { Controller } from "@hotwired/stimulus"

/**
 * Step Warnings Controller
 *
 * Fetches workflow health data and renders inline warning icons on step rows.
 * Connected to the builder container.
 *
 * Values:
 *   healthUrl  — GET endpoint returning JSON health payload
 *   fixUrl     — POST endpoint for autocorrect fixes
 *   mode       — "view" or "edit" (fix buttons hidden in view mode)
 *
 * Targets:
 *   publishBadge   — error count badge on Publish button
 *   toolbarIssues  — issue count in the toolbar
 *   icon           — warning icon spans on step rows (one per row)
 */
export default class extends Controller {
  static values = {
    healthUrl: String,
    fixUrl: String,
    mode: { type: String, default: "view" }
  }

  static targets = ["publishBadge", "toolbarIssues", "icon"]

  connect() {
    this.debounceTimer = null
    this.openPopover = null
    this.healthData = null

    // Close popover on click outside
    this.boundClosePopover = this.handleDocumentClick.bind(this)
    document.addEventListener("click", this.boundClosePopover)

    // Close popover on Escape
    this.boundKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.boundKeydown)

    // Listen for autosave completions (Turbo form submissions)
    this.boundOnSubmitEnd = this.onSubmitEnd.bind(this)
    this.element.addEventListener("turbo:submit-end", this.boundOnSubmitEnd)

    // Listen for custom event from disconnect fetch path in inline_autosave
    this.boundOnHealthCheck = this.onHealthCheckNeeded.bind(this)
    document.addEventListener("health:check-needed", this.boundOnHealthCheck)

    // Listen for new step rows being added via Turbo Stream
    this.boundOnStreamRender = this.onStreamRender.bind(this)
    document.addEventListener("turbo:before-stream-render", this.boundOnStreamRender)

    // Initial fetch with a small delay so step list renders first
    setTimeout(() => this.fetchHealth(), 300)
  }

  disconnect() {
    clearTimeout(this.debounceTimer)
    document.removeEventListener("click", this.boundClosePopover)
    document.removeEventListener("keydown", this.boundKeydown)
    this.element.removeEventListener("turbo:submit-end", this.boundOnSubmitEnd)
    document.removeEventListener("health:check-needed", this.boundOnHealthCheck)
    document.removeEventListener("turbo:before-stream-render", this.boundOnStreamRender)
    this.dismissPopover()
  }

  onSubmitEnd() {
    this.debouncedFetch()
  }

  onHealthCheckNeeded() {
    this.debouncedFetch()
  }

  onStreamRender() {
    this.debouncedFetch()
  }

  debouncedFetch() {
    clearTimeout(this.debounceTimer)
    this.debounceTimer = setTimeout(() => this.fetchHealth(), 500)
  }

  async fetchHealth() {
    if (!this.healthUrlValue) return

    try {
      const response = await fetch(this.healthUrlValue, {
        headers: { "Accept": "application/json" }
      })
      if (!response.ok) throw new Error(`Health fetch failed: ${response.status}`)

      const data = await response.json()
      this.healthData = data
      this.render(data)
    } catch (error) {
      console.warn("Health check failed:", error)
      this.clearAllWarnings()
    }
  }

  render(data) {
    const { issues, summary } = data

    // Update step row icons and tints
    this.renderStepIcons(issues)

    // Update publish badge
    this.renderPublishBadge(summary.errors)

    // Update toolbar issues
    this.renderToolbarIssues(summary.total)
  }

  renderStepIcons(issues) {
    const rows = this.element.querySelectorAll(".builder__list-row[data-step-uuid]")

    rows.forEach(row => {
      const uuid = row.dataset.stepUuid
      const stepIssues = issues[uuid]

      // Clear previous state
      row.classList.remove("has-error", "has-warning")

      // Find the warning icon in this row
      const icon = row.querySelector(".step-warning-icon")
      if (!icon) return

      if (!stepIssues || stepIssues.length === 0) {
        icon.hidden = true
        icon.className = "step-warning-icon"
        icon.removeAttribute("role")
        icon.removeAttribute("aria-label")
        icon.removeAttribute("tabindex")
        this.clearElement(icon)
        return
      }

      // Determine highest severity
      const hasError = stepIssues.some(i => i.severity === "error")
      const severity = hasError ? "error" : "warning"

      // Update row tint
      row.classList.add(hasError ? "has-error" : "has-warning")

      // Update icon
      icon.hidden = false
      icon.className = `step-warning-icon step-warning-icon--${severity}`
      icon.setAttribute("role", "button")
      icon.setAttribute("aria-label", `${stepIssues.length} issue${stepIssues.length === 1 ? "" : "s"} on this step`)
      icon.setAttribute("tabindex", "0")
      this.clearElement(icon)
      icon.appendChild(hasError ? this.createErrorIcon() : this.createWarningIcon())

      // Wire click to open popover
      icon.onclick = (e) => {
        e.stopPropagation()
        this.togglePopover(icon, uuid, stepIssues)
      }
      icon.onkeydown = (e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault()
          e.stopPropagation()
          this.togglePopover(icon, uuid, stepIssues)
        }
      }
    })
  }

  renderPublishBadge(errorCount) {
    if (!this.hasPublishBadgeTarget) return

    if (errorCount > 0) {
      this.publishBadgeTarget.hidden = false
      this.publishBadgeTarget.textContent = errorCount > 9 ? "9+" : errorCount

      // Update Publish button aria-label
      const btn = this.publishBadgeTarget.closest(".builder__publish-wrapper")?.querySelector("button")
      if (btn) btn.setAttribute("aria-label", `Publish (${errorCount} error${errorCount === 1 ? "" : "s"})`)
    } else {
      this.publishBadgeTarget.hidden = true
      const btn = this.publishBadgeTarget.closest(".builder__publish-wrapper")?.querySelector("button")
      if (btn) btn.removeAttribute("aria-label")
    }
  }

  renderToolbarIssues(total) {
    if (!this.hasToolbarIssuesTarget) return

    if (total > 0) {
      this.toolbarIssuesTarget.hidden = false
      this.clearElement(this.toolbarIssuesTarget)
      this.toolbarIssuesTarget.appendChild(this.createWarningIcon())
      this.toolbarIssuesTarget.appendChild(document.createTextNode(` ${total} issue${total === 1 ? "" : "s"}`))
    } else {
      this.toolbarIssuesTarget.hidden = true
      this.clearElement(this.toolbarIssuesTarget)
    }
  }

  clearAllWarnings() {
    this.element.querySelectorAll(".builder__list-row").forEach(row => {
      row.classList.remove("has-error", "has-warning")
    })
    this.element.querySelectorAll(".step-warning-icon").forEach(icon => {
      icon.hidden = true
      this.clearElement(icon)
    })
    if (this.hasPublishBadgeTarget) this.publishBadgeTarget.hidden = true
    if (this.hasToolbarIssuesTarget) {
      this.toolbarIssuesTarget.hidden = true
      this.clearElement(this.toolbarIssuesTarget)
    }
    this.dismissPopover()
  }

  // Popover management
  togglePopover(anchor, uuid, issues) {
    if (this.openPopover && this.openPopover.dataset.uuid === uuid) {
      this.dismissPopover()
      return
    }
    this.dismissPopover()
    this.showPopover(anchor, uuid, issues)
  }

  showPopover(anchor, uuid, issues) {
    const popover = document.createElement("div")
    popover.className = "step-warning-popover"
    popover.setAttribute("role", "dialog")
    popover.setAttribute("aria-label", `${issues.length} issues`)
    popover.dataset.uuid = uuid

    const header = document.createElement("div")
    header.className = "step-warning-popover__header"
    header.id = `warning-popover-header-${uuid}`
    header.textContent = `${issues.length} issue${issues.length === 1 ? "" : "s"}`
    popover.appendChild(header)

    popover.setAttribute("aria-labelledby", header.id)

    const list = document.createElement("div")
    list.className = "step-warning-popover__list"

    issues.forEach(issue => {
      const item = document.createElement("div")
      item.className = "step-warning-popover__item"

      const iconSpan = document.createElement("span")
      iconSpan.className = "step-warning-popover__item-icon"
      iconSpan.appendChild(issue.severity === "error" ? this.createErrorIcon() : this.createWarningIcon())
      iconSpan.style.color = issue.severity === "error" ? "var(--color-negative)" : "var(--color-warning)"
      item.appendChild(iconSpan)

      const text = document.createElement("span")
      text.className = "step-warning-popover__item-text"
      text.textContent = issue.message
      item.appendChild(text)

      if (issue.fixable && issue.fix_type && this.modeValue === "edit") {
        const fixBtn = document.createElement("button")
        fixBtn.className = "step-warning-popover__item-fix btn btn--sm"
        fixBtn.textContent = "Fix"
        fixBtn.type = "button"
        fixBtn.onclick = (e) => {
          e.stopPropagation()
          this.executeFix(uuid, issue.fix_type, fixBtn)
        }
        item.appendChild(fixBtn)
      }

      list.appendChild(item)
    })

    popover.appendChild(list)

    // Position relative to the anchor's row
    const row = anchor.closest(".builder__list-row")
    if (row) {
      row.style.position = "relative"
      row.appendChild(popover)
    }

    this.openPopover = popover

    // Focus the first fix button or the popover itself
    const firstFix = popover.querySelector(".step-warning-popover__item-fix")
    if (firstFix) {
      firstFix.focus()
    } else {
      popover.setAttribute("tabindex", "-1")
      popover.focus()
    }
  }

  dismissPopover() {
    if (this.openPopover) {
      this.openPopover.remove()
      this.openPopover = null
    }
  }

  handleDocumentClick(event) {
    if (!this.openPopover) return
    if (this.openPopover.contains(event.target)) return
    if (event.target.closest(".step-warning-icon")) return
    this.dismissPopover()
  }

  handleKeydown(event) {
    if (event.key === "Escape" && this.openPopover) {
      this.dismissPopover()
    }
  }

  async executeFix(stepUuid, fixType, button) {
    // Build confirm message
    const row = this.element.querySelector(`[data-step-uuid="${stepUuid}"]`)
    const stepTitle = row?.querySelector(".builder__step-title")?.textContent?.trim() || "this step"

    let message
    if (fixType === "connect_next") {
      message = `Connect "${stepTitle}" to the next step?`
    } else if (fixType === "add_resolve_after") {
      message = `Add a new Resolve step after "${stepTitle}"?`
    } else {
      return
    }

    if (!confirm(message)) return

    button.disabled = true
    button.textContent = "Fixing..."

    try {
      const token = document.querySelector('meta[name="csrf-token"]')?.content
      const response = await fetch(this.fixUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": token,
          "Accept": "text/vnd.turbo-stream.html"
        },
        body: JSON.stringify({ fix_type: fixType, step_uuid: stepUuid })
      })

      if (response.ok) {
        const html = await response.text()
        Turbo.renderStreamMessage(html)
        this.dismissPopover()
        // Re-fetch health after the fix takes effect
        setTimeout(() => this.fetchHealth(), 300)
      } else {
        button.disabled = false
        button.textContent = "Fix"
        console.warn("Fix failed:", response.status)
      }
    } catch (error) {
      button.disabled = false
      button.textContent = "Fix"
      console.warn("Fix error:", error)
    }
  }

  // DOM helpers — safe methods, no innerHTML
  clearElement(el) {
    while (el.firstChild) el.removeChild(el.firstChild)
  }

  createSvg(paths) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg")
    svg.setAttribute("width", "14")
    svg.setAttribute("height", "14")
    svg.setAttribute("viewBox", "0 0 24 24")
    svg.setAttribute("fill", "none")
    svg.setAttribute("stroke", "currentColor")
    svg.setAttribute("stroke-width", "2")
    svg.setAttribute("stroke-linecap", "round")
    svg.setAttribute("stroke-linejoin", "round")

    paths.forEach(({ tag, attrs }) => {
      const el = document.createElementNS("http://www.w3.org/2000/svg", tag)
      Object.entries(attrs).forEach(([k, v]) => el.setAttribute(k, v))
      svg.appendChild(el)
    })

    return svg
  }

  createErrorIcon() {
    return this.createSvg([
      { tag: "circle", attrs: { cx: "12", cy: "12", r: "10" } },
      { tag: "line", attrs: { x1: "12", y1: "8", x2: "12", y2: "12" } },
      { tag: "line", attrs: { x1: "12", y1: "16", x2: "12.01", y2: "16" } }
    ])
  }

  createWarningIcon() {
    return this.createSvg([
      { tag: "path", attrs: { d: "M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z" } },
      { tag: "line", attrs: { x1: "12", y1: "9", x2: "12", y2: "13" } },
      { tag: "line", attrs: { x1: "12", y1: "17", x2: "12.01", y2: "17" } }
    ])
  }
}
