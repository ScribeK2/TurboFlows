import { Controller } from "@hotwired/stimulus"

// Polls a heartbeat endpoint to detect session expiry.
// When the session is gone, shows an overlay and redirects to sign-in.
export default class extends Controller {
  static values = {
    url: String,          // heartbeat endpoint
    signInUrl: String,    // where to redirect
    interval: { type: Number, default: 60 }  // poll interval in seconds
  }

  connect() {
    this.expired = false
    this.startPolling()
    document.addEventListener("visibilitychange", this.handleVisibility)
  }

  disconnect() {
    this.stopPolling()
    document.removeEventListener("visibilitychange", this.handleVisibility)
  }

  startPolling() {
    this.stopPolling()
    this.timer = setInterval(() => this.check(), this.intervalValue * 1000)
  }

  stopPolling() {
    if (this.timer) {
      clearInterval(this.timer)
      this.timer = null
    }
  }

  // Check immediately when tab regains focus
  handleVisibility = () => {
    if (!document.hidden && !this.expired) {
      this.check()
      this.startPolling()
    }
  }

  async check() {
    if (this.expired) return

    try {
      const response = await fetch(this.urlValue, {
        method: "GET",
        headers: { "X-Requested-With": "XMLHttpRequest" },
        credentials: "same-origin"
      })

      if (response.status === 401) {
        this.handleExpired()
      }
    } catch {
      // Network error — don't treat as expired, will retry next interval
    }
  }

  handleExpired() {
    this.expired = true
    this.stopPolling()
    this.showOverlay()
  }

  showOverlay() {
    const overlay = document.createElement("div")
    overlay.className = "session-expired"
    overlay.setAttribute("role", "alertdialog")
    overlay.setAttribute("aria-modal", "true")
    overlay.setAttribute("aria-label", "Session expired")

    const card = document.createElement("div")
    card.className = "session-expired__card"

    // Clock icon
    const iconNS = "http://www.w3.org/2000/svg"
    const svg = document.createElementNS(iconNS, "svg")
    svg.classList.add("session-expired__icon")
    svg.setAttribute("viewBox", "0 0 24 24")
    svg.setAttribute("fill", "none")
    svg.setAttribute("stroke", "currentColor")
    svg.setAttribute("stroke-width", "1.5")
    svg.setAttribute("aria-hidden", "true")
    const path = document.createElementNS(iconNS, "path")
    path.setAttribute("stroke-linecap", "round")
    path.setAttribute("stroke-linejoin", "round")
    path.setAttribute("d", "M12 6v6l4 2m6-2a10 10 0 11-20 0 10 10 0 0120 0z")
    svg.appendChild(path)

    const title = document.createElement("h2")
    title.className = "session-expired__title"
    title.textContent = "Session expired"

    const message = document.createElement("p")
    message.className = "session-expired__message"
    message.textContent = "Your session has timed out due to inactivity. Sign in again to continue."

    const link = document.createElement("a")
    link.href = this.signInUrlValue
    link.className = "btn btn--primary session-expired__btn"
    link.textContent = "Sign in"

    card.append(svg, title, message, link)
    overlay.appendChild(card)
    document.body.appendChild(overlay)

    // Auto-redirect after 8 seconds
    setTimeout(() => {
      window.location.href = this.signInUrlValue
    }, 8000)
  }
}
