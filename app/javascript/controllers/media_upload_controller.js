import { Controller } from "@hotwired/stimulus"

// Handles media file uploads with drag-and-drop, previews, and removal.
export default class extends Controller {
  static targets = ["input", "preview", "dropzone"]

  connect() {
    this.boundDragOver = this.dragOver.bind(this)
    this.boundDragLeave = this.dragLeave.bind(this)
    this.boundDrop = this.drop.bind(this)

    this.dropzoneTarget.addEventListener("dragover", this.boundDragOver)
    this.dropzoneTarget.addEventListener("dragleave", this.boundDragLeave)
    this.dropzoneTarget.addEventListener("drop", this.boundDrop)
  }

  disconnect() {
    this.dropzoneTarget.removeEventListener("dragover", this.boundDragOver)
    this.dropzoneTarget.removeEventListener("dragleave", this.boundDragLeave)
    this.dropzoneTarget.removeEventListener("drop", this.boundDrop)
  }

  fileSelected(event) {
    const files = event.target.files
    if (files.length > 0) {
      this.showPreviews(files)
    }
  }

  dragOver(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.add("is-dragover")
  }

  dragLeave(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.remove("is-dragover")
  }

  drop(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.remove("is-dragover")

    const files = event.dataTransfer.files
    if (files.length > 0) {
      const dataTransfer = new DataTransfer()
      for (const file of files) {
        if (this.isAllowedType(file)) {
          dataTransfer.items.add(file)
        }
      }
      if (dataTransfer.files.length > 0) {
        this.inputTarget.files = dataTransfer.files
        this.showPreviews(dataTransfer.files)
      }
    }
  }

  showPreviews(files) {
    this.previewTarget.replaceChildren()

    for (const file of files) {
      const item = document.createElement("div")
      item.classList.add("media-preview-item")

      if (file.type.startsWith("image/")) {
        const img = document.createElement("img")
        img.classList.add("media-preview-item__thumb")
        img.alt = file.name
        img.src = URL.createObjectURL(file)
        img.onload = () => URL.revokeObjectURL(img.src)
        img.onerror = () => URL.revokeObjectURL(img.src)
        item.appendChild(img)
      } else if (file.type.startsWith("video/")) {
        const icon = document.createElement("span")
        icon.classList.add("media-preview-item__icon")
        icon.textContent = "\u{1F3AC}"
        item.appendChild(icon)
      } else {
        const icon = document.createElement("span")
        icon.classList.add("media-preview-item__icon")
        icon.textContent = "\u{1F4C4}"
        item.appendChild(icon)
      }

      const info = document.createElement("span")
      info.classList.add("media-preview-item__name")
      info.textContent = `${file.name} (${this.formatFileSize(file.size)})`
      item.appendChild(info)

      this.previewTarget.appendChild(item)
    }
  }

  isAllowedType(file) {
    const allowed = [
      "image/png", "image/jpeg", "image/gif", "image/webp", "image/svg+xml",
      "video/mp4", "video/webm",
      "application/pdf"
    ]
    return allowed.includes(file.type)
  }

  formatFileSize(bytes) {
    if (bytes === 0) return "0 Bytes"
    const k = 1024
    const sizes = ["Bytes", "KB", "MB", "GB"]
    const i = Math.floor(Math.log(bytes) / Math.log(k))
    return Math.round(bytes / Math.pow(k, i) * 100) / 100 + " " + sizes[i]
  }
}
