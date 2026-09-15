import { Controller } from "@hotwired/stimulus"
import { DirectUpload } from "@rails/activestorage"
import { flashAlert } from "services/flash"

// A file chosen (or dropped) here is uploaded straight to Active Storage, with
// a progress row while it goes, then attached to the step by a small POST that
// answers with the attachment list. The step's own autosave never sees bytes.
export default class extends Controller {
  static targets = ["input", "dropzone", "pending"]
  static values = {
    url: String,
    directUploadUrl: String,
    maxBytes: Number,
    allowedTypes: Array
  }

  fileSelected(event) {
    this.uploadAll(event.target.files)
    // Clear the input so choosing the same file again fires change again.
    event.target.value = ""
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
    this.uploadAll(event.dataTransfer.files)
  }

  uploadAll(files) {
    for (const file of files) this.upload(file)
  }

  upload(file) {
    if (!this.allowedTypesValue.includes(file.type)) {
      flashAlert(`${file.name} must be an image, video, or PDF.`)
      return
    }
    if (file.size > this.maxBytesValue) {
      flashAlert(`${file.name} is larger than 10 MB.`)
      return
    }

    const row = this.pendingRow(file)
    this.pendingTarget.appendChild(row)

    const delegate = {
      directUploadWillStoreFileWithXHR: (xhr) => {
        xhr.upload.addEventListener("progress", (event) => {
          if (event.lengthComputable) row.querySelector("progress").value = Math.round((event.loaded / event.total) * 100)
        })
      }
    }

    new DirectUpload(file, this.directUploadUrlValue, delegate).create((error, blob) => {
      if (error) {
        row.remove()
        flashAlert(`${file.name} didn't upload. Check the connection and choose it again.`)
        return
      }
      this.queueAttach(blob.signed_id, row)
    })
  }

  // Direct uploads may run in parallel, but the attach POSTs must not: the
  // server's `attach` reassigns the step's whole attachment list, so two
  // overlapping POSTs can both read the same starting list and the second's
  // save deletes what the first just added. Chaining onto one promise makes
  // each attach wait for the previous one to finish.
  queueAttach(signedId, row) {
    this.attachQueue = (this.attachQueue || Promise.resolve()).then(() => this.attach(signedId, row))
  }

  async attach(signedId, row) {
    const body = new FormData()
    body.append("signed_id", signedId)

    let response
    try {
      response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
          "Accept": "text/vnd.turbo-stream.html"
        },
        body
      })
    } catch {
      row.remove()
      flashAlert("The file uploaded but couldn't be attached. Choose it again.")
      return
    }

    row.remove()

    // fetch follows a redirect itself, so a lost session or lost access (the
    // controller's ensure_can_edit!, or Devise's own redirect to sign in)
    // arrives here as a 200 with no turbo-stream to render — response.ok
    // alone would read that as success. response.redirected catches it.
    if (response.redirected) {
      flashAlert("The file could not be attached. Reload and try again.")
      return
    }

    const html = await response.text()
    // Success streams the list; a refusal streams the flash that says why.
    if (response.ok || response.status === 422) {
      if (html.trim()) Turbo.renderStreamMessage(html)
    } else {
      flashAlert("The file could not be attached. Reload and try again.")
    }
  }

  pendingRow(file) {
    const row = document.createElement("div")
    row.className = "media-list__row media-list__row--pending"

    const name = document.createElement("span")
    name.className = "media-list__name"
    name.textContent = file.name
    row.appendChild(name)

    const progress = document.createElement("progress")
    progress.className = "media-list__progress"
    progress.max = 100
    progress.value = 0
    progress.setAttribute("aria-label", `Uploading ${file.name}`)
    row.appendChild(progress)

    return row
  }
}
