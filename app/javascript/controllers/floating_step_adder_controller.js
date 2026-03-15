import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["fab", "popover", "icon", "toggleButton"]

  connect() {
    this.isOpen = false
    this.observeSentinel()
    this.boundCloseOnOutsideClick = this.closeOnOutsideClick.bind(this)
    document.addEventListener("click", this.boundCloseOnOutsideClick)
  }

  disconnect() {
    if (this.observer) {
      this.observer.disconnect()
    }
    document.removeEventListener("click", this.boundCloseOnOutsideClick)
  }

  observeSentinel() {
    // The sentinel is inside the workflow-builder scope, not inside this controller's element
    const sentinel = document.querySelector("[data-floating-step-adder-target='sentinel']")
    if (!sentinel) return

    this.observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            this.hideFab()
          } else {
            this.showFab()
          }
        })
      },
      { threshold: 0 }
    )

    this.observer.observe(sentinel)
  }

  showFab() {
    this.fabTarget.classList.remove("is-hidden")
    this.fabTarget.classList.add("is-visible")
  }

  hideFab() {
    this.fabTarget.classList.add("is-hidden")
    this.fabTarget.classList.remove("is-visible")
    this.close()
  }

  toggle(event) {
    event.stopPropagation()
    if (this.isOpen) {
      this.close()
    } else {
      this.open()
    }
  }

  open() {
    this.isOpen = true
    this.popoverTarget.classList.remove("is-hidden")
    this.iconTarget.style.transform = "rotate(45deg)"
  }

  close() {
    this.isOpen = false
    this.popoverTarget.classList.add("is-hidden")
    this.iconTarget.style.transform = "rotate(0deg)"
  }

  addStep(event) {
    event.preventDefault()
    event.stopPropagation()

    const stepType = event.currentTarget.dataset.stepType
    if (!stepType) return

    // Find the workflow-builder controller element and get its Stimulus controller instance
    const builderElement = document.querySelector("[data-controller*='workflow-builder']")
    if (!builderElement) return

    const builderController = this.application.getControllerForElementAndIdentifier(builderElement, "workflow-builder")
    if (!builderController) return

    // Call addStepDirect with a synthetic event that matches the expected interface
    builderController.addStepDirect({
      preventDefault() {},
      currentTarget: { dataset: { stepType } }
    })

    this.close()
  }

  closeOnOutsideClick(event) {
    if (!this.isOpen) return
    if (this.element.contains(event.target)) return
    this.close()
  }
}
