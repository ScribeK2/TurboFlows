import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="dark-mode"
export default class extends Controller {
  static targets = ["sunIcon", "moonIcon"]

  connect() {
    this.initializeTheme()
  }

  initializeTheme() {
    const savedTheme = localStorage.getItem("theme")
    const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches

    if (savedTheme === "dark" || (!savedTheme && prefersDark)) {
      document.documentElement.dataset.theme = "dark"
      this.updateIcons(true)
    } else {
      document.documentElement.dataset.theme = "light"
      this.updateIcons(false)
    }
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()

    // Suppress all CSS transitions for an instant theme switch
    this.disableTransitions()

    if (document.documentElement.dataset.theme === "dark") {
      this.enableLightMode()
    } else {
      this.enableDarkMode()
    }

    // Re-enable transitions after the browser has painted the new theme
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        this.enableTransitions()
      })
    })
  }

  enableDarkMode() {
    document.documentElement.dataset.theme = "dark"
    localStorage.setItem("theme", "dark")
    this.updateIcons(true)
  }

  enableLightMode() {
    document.documentElement.dataset.theme = "light"
    localStorage.setItem("theme", "light")
    this.updateIcons(false)
  }

  updateIcons(isDark) {
    if (this.hasSunIconTarget && this.hasMoonIconTarget) {
      if (isDark) {
        this.sunIconTarget.classList.remove("is-hidden")
        this.moonIconTarget.classList.add("is-hidden")
      } else {
        this.sunIconTarget.classList.add("is-hidden")
        this.moonIconTarget.classList.remove("is-hidden")
      }

      const activeIcon = isDark ? this.sunIconTarget : this.moonIconTarget
      activeIcon.animate([
        { transform: "rotate(-90deg)", opacity: 0 },
        { transform: "rotate(0deg)", opacity: 1 }
      ], { duration: 250, easing: "cubic-bezier(0.16, 1, 0.3, 1)" })
    }
  }

  disableTransitions() {
    if (!this.styleTag) {
      this.styleTag = document.createElement("style")
      this.styleTag.textContent = "*, *::before, *::after { transition: none !important; }"
    }
    document.head.appendChild(this.styleTag)
  }

  enableTransitions() {
    if (this.styleTag && this.styleTag.parentNode) {
      this.styleTag.parentNode.removeChild(this.styleTag)
    }
  }
}
