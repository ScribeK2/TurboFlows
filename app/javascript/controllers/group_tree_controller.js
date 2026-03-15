import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  toggle(event) {
    const button = event.currentTarget
    const groupId = button.dataset.groupId
    const childrenList = this.element.querySelector(`[data-children][data-group-id="${groupId}"]`)
    const icon = button.querySelector('[data-icon]')
    
    if (!childrenList) return
    
    // Toggle visibility
    childrenList.classList.toggle('is-hidden')
    
    // Rotate icon
    if (icon) {
      icon.classList.toggle('rotate-90')
    }
  }
}

