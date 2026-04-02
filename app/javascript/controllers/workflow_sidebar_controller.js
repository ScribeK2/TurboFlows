import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["sidebar", "toggleIcon"]

  connect() {
    // Auto-expand groups that contain the selected group
    this.expandSelectedPath()
  }

  toggle(event) {
    event.stopPropagation()
    this.sidebarTarget.classList.toggle("is-hidden")

    // Rotate icon (if it's a hamburger menu icon)
    if (this.hasToggleIconTarget) {
      // Toggle between hamburger and X icon.
      // Trust boundary: static SVG path data only, no user data interpolated.
      const isHidden = this.sidebarTarget.classList.contains("is-hidden")
      if (isHidden) {
        this.toggleIconTarget.innerHTML = '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16" />'
      } else {
        this.toggleIconTarget.innerHTML = '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />'
      }
    }
  }

  toggleGroup(event) {
    event.stopPropagation()
    const button = event.currentTarget
    const groupId = button.dataset.groupId
    const childrenList = this.element.querySelector(`[data-children][data-group-id="${groupId}"]`)
    const icon = button.querySelector('[data-icon]')
    
    if (!childrenList) return
    
    // Smooth toggle with animation
    const isHidden = childrenList.classList.contains('is-hidden')
    
    if (isHidden) {
      // Expand
      childrenList.style.maxHeight = '0'
      childrenList.classList.remove('is-hidden')
      // Force reflow
      childrenList.offsetHeight
      childrenList.style.maxHeight = childrenList.scrollHeight + 'px'
      
      // Update aria-expanded
      button.setAttribute('aria-expanded', 'true')
      
      // Rotate icon
      if (icon) {
        icon.classList.add('rotate-90')
      }
      
      // Reset max-height after animation
      setTimeout(() => {
        childrenList.style.maxHeight = 'none'
      }, 300)
    } else {
      // Collapse
      childrenList.style.maxHeight = childrenList.scrollHeight + 'px'
      // Force reflow
      childrenList.offsetHeight
      childrenList.style.maxHeight = '0'
      
      // Update aria-expanded
      button.setAttribute('aria-expanded', 'false')
      
      // Rotate icon
      if (icon) {
        icon.classList.remove('rotate-90')
      }
      
      // Hide after animation
      setTimeout(() => {
        childrenList.classList.add('is-hidden')
        childrenList.style.maxHeight = ''
      }, 300)
    }
  }

  expandSelectedPath() {
    // Find all groups that should be expanded (ancestors of selected group)
    const selectedGroupItem = this.element.querySelector('.group-sidebar-item a.is-active')
    if (!selectedGroupItem) return
    
    // Walk up the tree and expand all parent groups
    let current = selectedGroupItem.closest('.group-sidebar-item')
    while (current) {
      const groupId = current.dataset.groupId
      if (groupId) {
        const childrenList = this.element.querySelector(`[data-children][data-group-id="${groupId}"]`)
        const toggleButton = current.querySelector(`[data-group-id="${groupId}"].group-toggle`)
        
        if (childrenList && childrenList.classList.contains('is-hidden')) {
          // Expand without animation for initial load
          childrenList.classList.remove('is-hidden')
          childrenList.style.maxHeight = 'none'
          const icon = toggleButton?.querySelector('[data-icon]')
          if (icon) {
            icon.classList.add('rotate-90')
          }
          if (toggleButton) {
            toggleButton.setAttribute('aria-expanded', 'true')
          }
        }
      }
      
      // Move to parent
      current = current.parentElement?.closest('.group-sidebar-item')
    }
  }

  handleKeydown(event) {
    const item = event.currentTarget
    const groupId = item.dataset.groupId
    const toggleButton = item.querySelector(`[data-group-id="${groupId}"].group-toggle`)
    const link = item.querySelector('a')
    
    switch(event.key) {
      case 'ArrowRight':
        if (toggleButton && item.querySelector('[data-children]')) {
          event.preventDefault()
          const childrenList = item.querySelector(`[data-children][data-group-id="${groupId}"]`)
          if (childrenList && childrenList.classList.contains('is-hidden')) {
            toggleButton.click()
          }
        }
        break
      case 'ArrowLeft':
        if (toggleButton && item.querySelector('[data-children]')) {
          event.preventDefault()
          const childrenList = item.querySelector(`[data-children][data-group-id="${groupId}"]`)
          if (childrenList && !childrenList.classList.contains('is-hidden')) {
            toggleButton.click()
          }
        }
        break
      case 'Enter':
      case ' ':
        if (link && document.activeElement === item) {
          event.preventDefault()
          link.click()
        }
        break
    }
  }

}

